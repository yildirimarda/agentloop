#!/usr/bin/env bash
#
# The single entry point. The agent picks its work from PLAN.md, and may
# append newly discovered work to it as it goes.
#
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

PLAN="PLAN.md"
IMAGE="${IMAGE:-agent}"
ENGINE="${ENGINE:-opencode}"     # opencode (free, OpenRouter) | claude (paid, Anthropic)
MODE="plan"
COUNT=1
WAIT=1
TIMEOUT_MIN=45
CI_RETRIES=1
STALL_MIN=45            # kill a session that emits no event for this long (0 = off)
RUN_ID="$$-$(date +%s)"
CONTAINER_NAME=""
AGENT_SEQ=0
WD_PID=""
SNAP=""
SKILLSNAP=""
SKILLS_ADDED=0

MODEL=""
USE_GRAPH=1
GRAPH_CONTEXT=1         # seed item prompts with a knowledge-graph excerpt
GRAPH_BUDGET=1200       # token budget of that excerpt (graphify query --budget)
DISCOVER=1
MAX_GROWTH=10
AUTO_REPLAN=0
AMBITIOUS=0
HEADROOM=0
LEARN=1                 # sessions may record project skills in .agents/skills/
ARG_TEXT=""
ANTHROPIC_KEY=""
SKILLS_DIR=".agents/skills"

# ── Local per-machine overrides: .agentloop.local (gitignored) ───────────────
# Change model/engine without touching git. KEY=VALUE lines, no quotes:
#   MODEL=openrouter/vendor/model
#   ENGINE=opencode          (or claude)
#   CI_RETRIES=5
#   TIMEOUT_MIN=40           (minutes to wait for a PR merge)
#   STALL_MIN=45             (kill a session silent this long; 0 = off)
#   LEARN=0                  (forbid sessions to record project skills)
#   GRAPH_CONTEXT=0          (don't seed prompts with a graph excerpt)
#   GRAPH_BUDGET=1200        (token budget of that excerpt)
# Precedence: CLI flags > this file > committed defaults (opencode.json).
if [[ -f "$REPO_DIR/.agentloop.local" ]]; then
  while IFS='=' read -r _k _v; do
    [[ "$_k" =~ ^[A-Z_]+$ ]] || continue
    case "$_k" in
      ENGINE|MODEL|CI_RETRIES|TIMEOUT_MIN|MAX_GROWTH|IMAGE|AUTO_REPLAN|HEADROOM|STALL_MIN|LEARN|GRAPH_CONTEXT|GRAPH_BUDGET)
        printf -v "$_k" '%s' "$_v" ;;
    esac
  done < "$REPO_DIR/.agentloop.local"
fi

usage() {
cat <<'EOF'
Usage: ./run.sh [mode] [options]

Modes
  (default)                 do the next unchecked item in PLAN.md
  -n, --tasks N             do the next N items, then stop ("all" = until done)
      --init "description"  bootstrap: draft PLAN.md for a new project
      --init -f brief.md    same, reading the description from a file
      --replan              audit the code against PLAN.md and correct it
      --task "text"         one-off task, ignores PLAN.md
      --next                dry run: print the next item. No API calls
      --skills              list the skills sessions can load (.agents/skills/)
                            and flag malformed ones. No API calls
      --reindex             rebuild the Graphify knowledge graph from scratch
      --github-setup        run setup-github.sh inside the container using the
                            "gh-admin" keychain token (no host gh login needed)

Options
  -e, --engine NAME         opencode (default; OpenRouter or NVIDIA NIM models),
                            claude (paid; Claude Code + Anthropic API key),
                            or codex (paid; OpenAI Codex CLI + CODEX_API_KEY)
      --no-discover         forbid the agent from adding items to PLAN.md
      --no-learn            forbid the agent from recording project skills
                            (persist: LEARN=0 in .agentloop.local)
      --max-growth N        abort if the plan grows by more than N items
                            over this run (default 10)
      --no-wait             don't wait for the PR to merge before the next item
      --timeout N           minutes to wait for a merge (default 45)
      --stall-timeout N     kill a session that produced no output for N
                            minutes — a hung model/API (default 45; 0 = off)
      --ci-retries N        when a PR's CI fails, automatically feed the
                            failing log back to the agent on the same branch
                            and let it fix, up to N times (default 1; 0 = off)
      --auto-replan         when the plan runs out mid-loop, run one replan
                            session so the agent proposes the next wave (as a
                            plan-labelled PR you review), then stop
      --ambitious           with --replan: besides auditing, propose real NEW
                            features from a product perspective, under a
                            "Proposed Features (vision)" milestone
      --headroom            (opencode engine only) route the session through a
                            local Headroom proxy in the container: compresses
                            old tool outputs before they reach the model,
                            delaying context compaction. Persist with
                            HEADROOM=1 in .agentloop.local
  -m, --model ID            override the model from opencode.json
                            (OpenRouter: openrouter/vendor/model; NVIDIA NIM:
                            nvidia-nim/vendor/model, keychain entry "nvidia")
      --no-graph            skip the Graphify index step (and graph context)
      --no-graph-context    don't seed item prompts with the knowledge graph's
                            answer for the item (persist: GRAPH_CONTEXT=0)
      --image NAME          container image (default "agent")
  -h, --help                this

Per-machine defaults (no git involved): put KEY=VALUE lines in
.agentloop.local (gitignored) — e.g. MODEL=openrouter/vendor/model,
ENGINE=claude, CI_RETRIES=5. CLI flags still win.

Examples
  ./run.sh --init "A CLI that validates CSV exports and loads them to Postgres"
  ./run.sh --next
  ./run.sh -n 5
  ./run.sh -n all --max-growth 20
  ./run.sh --task "the rate limiter leaks memory under load, fix it"
  ./run.sh --engine claude --init "..."      # plan with the strong paid model
  ./run.sh --engine claude --task "hard bug" # paid model for a hard one-off
EOF
}

# ── Argument parsing ─────────────────────────────────────────────────────────
while (( $# )); do
  case "$1" in
    -n|--tasks)     COUNT="${2:?-n needs a value}"; shift 2 ;;
    --init)         MODE="init"; shift ;;
    --replan)       MODE="replan"; shift ;;
    --task)         MODE="task"; ARG_TEXT="${2:?--task needs text}"; shift 2 ;;
    --next)         MODE="next"; shift ;;
    --skills)       MODE="skills"; shift ;;
    --reindex)      MODE="reindex"; shift ;;
    --github-setup) MODE="ghsetup"; shift ;;
    -f|--file)      f="${2:?-f needs a path}"
                    [[ -f "$f" ]] || { echo "error: file not found: $f" >&2; exit 1; }
                    ARG_TEXT="$(cat "$f")"; shift 2 ;;
    -e|--engine)    ENGINE="${2:?--engine needs opencode, claude or codex}"; shift 2 ;;
    --no-discover)  DISCOVER=0; shift ;;
    --no-learn)     LEARN=0; shift ;;
    --max-growth)   MAX_GROWTH="${2:?--max-growth needs a number}"; shift 2 ;;
    --no-wait)      WAIT=0; shift ;;
    --timeout)      TIMEOUT_MIN="${2:?--timeout needs minutes}"; shift 2 ;;
    --stall-timeout) STALL_MIN="${2:?--stall-timeout needs minutes}"; shift 2 ;;
    --ci-retries)   CI_RETRIES="${2:?--ci-retries needs a number}"; shift 2 ;;
    --auto-replan)  AUTO_REPLAN=1; shift ;;
    --ambitious)    AMBITIOUS=1; shift ;;
    --headroom)     HEADROOM=1; shift ;;
    -m|--model)     MODEL="${2:?-m needs a model id}"; shift 2 ;;
    --no-graph)     USE_GRAPH=0; shift ;;
    --no-graph-context) GRAPH_CONTEXT=0; shift ;;
    --image)        IMAGE="${2:?--image needs a name}"; shift 2 ;;
    -h|--help)      usage; exit 0 ;;
    -*)             echo "error: unknown option: $1  (try --help)" >&2; exit 1 ;;
    *)              ARG_TEXT="$1"; shift ;;
  esac
done

[[ "$COUNT" == "all" ]] && COUNT=9999

# ── Helpers ──────────────────────────────────────────────────────────────────
die()  { echo "error: $*" >&2; exit 1; }
info() { echo "  $*"; }
rule() { printf '%s\n' "────────────────────────────────────────────────────────"; }

# Note: `grep -c` prints 0 AND exits 1 when nothing matches, so the count has
# to be captured into a variable rather than piped through `|| echo 0`, which
# would emit the value twice and break the arithmetic below.
plan_count() {
  local pattern="$1" n
  [[ -f "$PLAN" ]] || { echo 0; return; }
  n="$(grep -cE "$pattern" "$PLAN" 2>/dev/null)" || n=0
  echo "${n:-0}"
}
plan_remaining()  { plan_count '^[[:space:]]*- \[ \]'; }
plan_done_count() { plan_count '^[[:space:]]*- \[[xX]\]'; }

plan_next() {
  [[ -f "$PLAN" ]] || return 1
  grep -m1 -E '^[[:space:]]*- \[ \]' "$PLAN" 2>/dev/null \
    | sed -E 's/^[[:space:]]*- \[ \][[:space:]]*//'
}

# Details of the next item: the run of indented lines directly under it
# (constraints, edge cases, acceptance criteria), ending at the first blank,
# unindented or checkbox line — a nested "- [ ]" stays a separate item. One
# indent level (two spaces or a tab) is removed; deeper nesting is kept.
# Must be read BEFORE tick_item_on_branch, which turns that "- [ ]" into
# "- [x]" on the work branch.
plan_details() {
  [[ -f "$PLAN" ]] || return 0
  awk '
    !found && /^[[:space:]]*- \[ \]/ { found = 1; next }
    found {
      if ($0 ~ /^[[:space:]]*$/ || $0 !~ /^(  |\t)/ || $0 ~ /^[[:space:]]*- \[[ xX]\]/) exit
      sub(/^(  |\t)/, "")
      print
    }' "$PLAN" 2>/dev/null
}

# ── Skills (.agents/skills/<name>/SKILL.md — the portable location) ──────────
# One value from a SKILL.md frontmatter (single-line fields only; quotes are
# stripped). Prints nothing when the field or the frontmatter is missing.
skill_field() {
  awk -v key="$2" '
    NR == 1 { if ($0 !~ /^---[[:space:]]*$/) exit; next }
    /^---[[:space:]]*$/ { exit }
    index($0, key ":") == 1 {
      v = substr($0, length(key) + 2)
      sub(/^[[:space:]]+/, "", v); sub(/[[:space:]]+$/, "", v)
      if (v ~ /^".*"$/ || v ~ /^'"'"'.*'"'"'$/) v = substr(v, 2, length(v) - 2)
      print v; exit
    }' "$1" 2>/dev/null
}

# Problems with one skill, one per line (empty = valid). Same rules every
# engine applies: name = directory, lowercase-hyphen, description 1-1024 chars.
skill_problems() {
  local f="$1" dir name desc
  dir="$(basename "$(dirname "$f")")"
  name="$(skill_field "$f" name)"
  desc="$(skill_field "$f" description)"
  [[ -n "$name" ]] || echo "no 'name' in the frontmatter"
  [[ -z "$name" || "$name" == "$dir" ]] || echo "name '$name' does not match its directory '$dir'"
  [[ "$dir" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || echo "directory name must be lowercase letters, digits and single hyphens"
  [[ -n "$desc" ]] || echo "no single-line 'description' in the frontmatter"
  (( ${#desc} <= 1024 )) || echo "description is longer than 1024 characters"
}

# Sorted list of installed skill files (one path per line).
skills_list() {
  ls -1 "$SKILLS_DIR"/*/SKILL.md 2>/dev/null | sort
}

# The subset of the given skill names that is installed, comma-separated —
# prompts name a skill only when it exists (an --only install may lack them).
skills_present() {
  local s out=""
  for s in "$@"; do
    [[ -f "$SKILLS_DIR/$s/SKILL.md" ]] && out="${out:+$out, }$s"
  done
  printf '%s' "$out"
}

# Secrets come from the macOS keychain. secret_optional prints nothing when an
# entry is missing; require_secret assigns into a variable IN THIS SHELL and
# dies here — a `die` inside "$(...)" would only end the subshell and let the
# run continue with an empty token.
secret_optional() {
  security find-generic-password -s "$1" -w 2>/dev/null || true
}
require_secret() {   # $1 = variable to set, $2 = keychain entry name
  local _val
  _val="$(secret_optional "$2")"
  [[ -n "$_val" ]] || die "keychain entry '$2' not found. Add it with:
  security add-generic-password -s $2 -a \"\$USER\" -w '<secret>'"
  printf -v "$1" '%s' "$_val"
}

case "$ENGINE" in
  opencode|claude|codex) : ;;
  *) die "unknown engine: '$ENGINE' (use opencode, claude or codex)" ;;
esac

# ── Dry run ──────────────────────────────────────────────────────────────────
if [[ "$MODE" == "next" ]]; then
  [[ -f "$PLAN" ]] || die "$PLAN not found. Bootstrap it:  ./run.sh --init \"<description>\""
  n="$(plan_next)" || true
  echo "done:      $(plan_done_count)"
  echo "remaining: $(plan_remaining)"
  echo "next:      ${n:-<nothing left>}"
  plan_details | sed 's/^/           /'
  if [[ "$(plan_done_count)" -eq 0 && "$(plan_remaining)" -eq 0 ]]; then
    echo
    echo "note: no '- [ ]' items found. If PLAN.md uses another format"
    echo "(tables, prose, bare [x] lines), convert it:  ./run.sh --replan"
  fi
  exit 0
fi

# ── Skills listing ───────────────────────────────────────────────────────────
if [[ "$MODE" == "skills" ]]; then
  _files="$(skills_list)"
  if [[ -z "$_files" ]]; then
    echo "no skills in $SKILLS_DIR/ — install agentloop's with: install.sh . --update"
    exit 0
  fi
  _bad=0
  for _kind in managed project; do
    if [[ "$_kind" == managed ]]; then echo "agentloop skills (managed — replaced on every update):"
    else echo; echo "project skills (yours, or recorded by earlier sessions):"; fi
    _n=0
    while IFS= read -r _f; do
      [[ -n "$_f" ]] || continue
      _dir="$(basename "$(dirname "$_f")")"
      case "$_dir" in agentloop-*) [[ "$_kind" == managed ]] || continue ;;
                      *)           [[ "$_kind" == project ]] || continue ;; esac
      _n=$(( _n + 1 ))
      _desc="$(skill_field "$_f" description)"
      (( ${#_desc} > 88 )) && _desc="${_desc:0:85}..."
      printf '  %-28s %s\n' "$_dir" "${_desc:-<no description>}"
      _probs="$(skill_problems "$_f")"
      if [[ -n "$_probs" ]]; then
        _bad=$(( _bad + 1 ))
        printf '%s\n' "$_probs" | sed 's/^/      ⚠ /'
      fi
    done <<< "$_files"
    (( _n )) || echo "  (none)"
  done
  if (( _bad )); then
    echo
    echo "$_bad skill(s) have problems — engines may skip them. Format: skill agentloop-skill-authoring."
    exit 1
  fi
  exit 0
fi

# ── Cheap guards before any heavy checks ─────────────────────────────────────
if [[ "$MODE" == "init" && -f "$PLAN" ]]; then
  # The installer ships a skeleton PLAN.md. If it is still byte-identical to
  # the one recorded in the .agentloop stamp, nobody has written a real plan
  # yet — let --init replace it. A modified plan stays protected.
  _stamp_hash="$({ grep '^hash:PLAN.md=' .agentloop 2>/dev/null || true; } | cut -d= -f2)"
  if command -v md5sum >/dev/null 2>&1; then _cur_hash="$(md5sum < "$PLAN" | cut -d' ' -f1)"
  else _cur_hash="$(md5 -q "$PLAN")"; fi
  if [[ -n "$_stamp_hash" && "$_cur_hash" == "$_stamp_hash" ]]; then
    info "PLAN.md is the untouched installer skeleton — --init will replace it"
  else
    die "$PLAN already exists — refusing to overwrite it.
Use ./run.sh --replan to restructure it, or delete the file first if you
really want a fresh start."
  fi
fi

# ── Preflight ────────────────────────────────────────────────────────────────
# Note: no host gh required. Every GitHub call — the agent's pushes, PR
# creation, and this script's own PR polling — runs inside the container,
# authenticated by a keychain token passed as GH_TOKEN.
docker info >/dev/null 2>&1 \
  || die "Docker is not running. Start it with 'colima start' or open Docker Desktop."
docker image inspect "$IMAGE" >/dev/null 2>&1 \
  || die "image '$IMAGE' not found. Build it:  docker build -t $IMAGE -f Dockerfile.agent ."

# A previous run killed with Ctrl+C / a crash can leave its container running
# against this checkout, which then fights the new run over the same files.
# Containers are labelled per repo, so stop any leftovers before starting.
# The label holds the full repo path, so other projects' containers are never
# touched. A container whose owning run.sh is still alive means a second run in
# this same checkout — refuse instead of killing it.
_stale="$(docker ps -a --filter "label=agentloop.repo=$REPO_DIR" \
          --format '{{.ID}} {{.Label "agentloop.run"}}' 2>/dev/null || true)"
if [[ -n "$_stale" ]]; then
  while read -r _cid _crun; do
    [[ -n "$_cid" ]] || continue
    _cpid="${_crun%%-*}"
    if [[ -n "$_cpid" && "$_cpid" =~ ^[0-9]+$ ]] && kill -0 "$_cpid" 2>/dev/null; then
      die "another run.sh (pid $_cpid) is already working in this checkout.
Stop it first (Ctrl+C in its terminal, or: kill $_cpid)."
    fi
    echo "  found a leftover agent container from an earlier run — stopping it"
    docker kill "$_cid" >/dev/null 2>&1 || true
  done <<< "$_stale"
fi

# The agent works in THIS checkout — same directory, same branches. Anything
# you leave uncommitted would be swept into its commits or dragged across its
# branch switches. Refuse to start dirty. (Corollary, not enforceable here:
# don't run git in this repo yourself while a run is in progress.)
if [[ "$MODE" != "ghsetup" ]] && git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  if [[ -n "$(git -C "$REPO_DIR" status --porcelain 2>/dev/null)" ]]; then
    die "working tree is not clean — commit or stash before starting a run.
The agent works in this same checkout; uncommitted changes would end up in
its commits. See what's pending with:  git status"
  fi
fi

GH_RUN_TOKEN=""
GH_AGENT_TOKEN=""
OPENROUTER_KEY=""
ANTHROPIC_KEY=""
CODEX_KEY=""
NVIDIA_KEY=""

if [[ "$MODE" == "ghsetup" ]]; then
  # One-time repo administration needs an admin-capable token, deliberately
  # separate from the agent's minimal token.
  require_secret GH_RUN_TOKEN gh-admin
else
  require_secret GH_AGENT_TOKEN gh-agent
  if [[ "$ENGINE" == "claude" ]]; then
    require_secret ANTHROPIC_KEY anthropic
    OPENROUTER_KEY="$(secret_optional openrouter)"
  elif [[ "$ENGINE" == "codex" ]]; then
    require_secret CODEX_KEY codex
    OPENROUTER_KEY="$(secret_optional openrouter)"
  else
    # NVIDIA NIM is optional; OpenRouter is required unless the chosen model is
    # an NVIDIA one. (A model set only in opencode.json is not visible here —
    # then put MODEL=nvidia-nim/... in .agentloop.local, or keep an openrouter
    # key around.)
    case "${MODEL:-}" in
      nvidia*/*)
        require_secret NVIDIA_KEY nvidia
        OPENROUTER_KEY="$(secret_optional openrouter)" ;;
      *)
        NVIDIA_KEY="$(secret_optional nvidia)"
        require_secret OPENROUTER_KEY openrouter ;;
    esac
  fi
fi

mkdir -p logs
[[ "$MODE" == "plan" && ! -f "$PLAN" ]] && \
  die "$PLAN not found. Bootstrap it first:  ./run.sh --init \"<project description>\""

# Claude Code reads project skills only from .claude/skills/, while opencode
# and codex read the portable .agents/skills/. For the claude engine that
# directory is mounted read-only as Claude's personal skills directory inside
# the container: the repo gains no duplicate tree, every engine sees the same
# skills, and the mount cannot be written through.
SKILLS_MOUNT=""
if [[ "$ENGINE" == "claude" && -d "$REPO_DIR/$SKILLS_DIR" ]]; then
  SKILLS_MOUNT="$REPO_DIR/$SKILLS_DIR:/home/agent/.claude/skills:ro"
fi

# ── Docker wrappers ──────────────────────────────────────────────────────────
in_container() {
  # agent-venv shadows /work/.venv with its own named volume so the
  # container's uv-managed venv never lands in the bind-mounted repo on the
  # host. Without this, a venv recreated inside the (Linux) container writes
  # symlinks like .venv/bin/python -> /usr/bin/python3; that exact path
  # differs across host/container, so reading the same absolute symlink from
  # macOS resolves to the Xcode Command Line Tools stub instead -- triggering
  # repeated CLT install prompts and a broken (ancient system) interpreter
  # the moment the host runs ruff/pytest/uv in a project managed by agentloop.
  docker run --rm \
    --label "agentloop.repo=$REPO_DIR" \
    --label "agentloop.run=$RUN_ID" \
    ${CONTAINER_NAME:+--name "$CONTAINER_NAME"} \
    --add-host=host.docker.internal:host-gateway \
    -v "$REPO_DIR:/work" \
    -v agent-venv:/work/.venv \
    -v agent-cache:/home/agent/.cache \
    -v agent-claude-home:/home/agent/.claude \
    ${SKILLS_MOUNT:+-v "$SKILLS_MOUNT"} \
    -e OPENROUTER_API_KEY="$OPENROUTER_KEY" \
    -e ANTHROPIC_API_KEY="$ANTHROPIC_KEY" \
    -e CODEX_API_KEY="$CODEX_KEY" \
    -e NVIDIA_API_KEY="$NVIDIA_KEY" \
    -e GH_TOKEN="${GH_RUN_TOKEN:-$GH_AGENT_TOKEN}" \
    -e GH_PROMPT_DISABLED=1 \
    -e GH_NO_UPDATE_NOTIFIER=1 \
    -e GRAPHIFY_QUERY_LOG_DISABLE=1 \
    "$IMAGE" "$@"
}

# All GitHub traffic goes through the container: gh reads GH_TOKEN, and git
# inside the image is configured to use gh as its credential helper. The host
# needs no gh login and no GitHub credentials at all.
gh_c()       { in_container gh "$@"; }
git_pull_c() { in_container git pull --ff-only --quiet >/dev/null 2>&1 || true; }

# Verified pull with retries — the post-merge accounting reads PLAN.md, and a
# silently failed pull makes it compare a STALE plan, mis-reporting ticks.
git_pull_verified() {
  local i
  for i in 1 2 3; do
    in_container git pull --ff-only --quiet >/dev/null 2>&1 && return 0
    sleep 5
  done
  return 1
}

# Keep the knowledge graph current so the agent can query it instead of reading
# whole files. Never fatal — Graphify is an optimisation, not a dependency.
# --code-only means pure tree-sitter: no LLM calls, no API key, no network.
graph_sync() {
  (( USE_GRAPH )) || return 0
  local force="${1:-}"
  echo "> syncing knowledge graph"
  if [[ -f graphify-out/graph.json && -z "$force" ]]; then
    in_container graphify update . --no-cluster >/dev/null 2>&1 \
      && info "graph updated" || info "graph update failed (continuing without it)"
  else
    in_container graphify extract . --code-only --no-cluster --force >/dev/null 2>&1 \
      && info "graph built" || info "graph build failed (continuing without it)"
  fi
}

# The graph only saves tokens if the model asks it — and many models never do
# (zero graphify calls is a common sight in session logs). So bash asks once,
# up front: a local query for the task text (tree-sitter graph: no LLM, no
# network), clipped, handed to the session as "Where to start". Never fatal:
# no graph, a graphify without `query`, or no match simply means no section.
graph_context() {
  local out
  (( USE_GRAPH && GRAPH_CONTEXT )) || return 0
  [[ -f graphify-out/graph.json ]] || return 0
  out="$(in_container graphify query "$1" --budget "$GRAPH_BUDGET" 2>/dev/null)" || return 0
  printf '%s\n' "$out" | head -60
}

# Prompt section for a graph excerpt (nothing when the excerpt is empty).
graph_section() {
  [[ -n "${1:-}" ]] || return 0
  cat <<EOF
Where to start — the codebase knowledge graph's answer for this task (a
starting point, not the whole truth: open only the cited files and lines, and
verify INFERRED edges in the source):

$1

EOF
}

# Live view: the raw event stream is unreadable NDJSON, so the terminal gets
# a human-readable heartbeat (tool calls + errors) while the FULL stream is
# tee'd to the log file. Handles both engines' event shapes.
stream_view() {
  if command -v jq >/dev/null 2>&1; then
    jq --unbuffered -Rr '
      fromjson? |
      # ── OpenCode events: payload lives under .part ──
      if .type == "tool_use" then
        # The model'\''s reasoning for this step rides along in provider
        # metadata — print it first, then the action itself.
        ( ( .part.metadata.openrouter.reasoning_details[]?
            | (.text // empty) | tostring
            | "  ⋯ " + gsub("[\\n\\r]+"; "\n  ⋯ ") ),
          ( "  → " + (.part.tool // .tool // .name // "tool")
            + ( (.part.state.input // {}) as $in
                | if $in.command  then ": " + ($in.command | gsub("[\\n\\r]+"; " ⏎ ") | .[0:100])
                  elif $in.filePath then ": " + ($in.filePath | tostring)
                  elif $in.pattern  then ": " + ($in.pattern | tostring | .[0:80])
                  elif $in.question then ": " + ($in.question | tostring | .[0:100])
                  else "" end ) ) )
      elif .type == "text" then
        ((.part.text // .text // empty) | tostring | "  " + gsub("\n"; "\n  "))
      elif .type == "step_finish" then
        ( .part.tokens.total // empty
          | if . >= 1000 then "        · step done (" + (. / 1000 | floor | tostring) + "k tok)"
            else "        · step done (" + tostring + " tok)" end )
      elif .type == "error" then
        "  ✖ " + ((.error.message? // .error // .message // "error") | tostring)
      # ── Claude Code events: assistant messages with content blocks ──
      elif .type == "assistant" then
        (.message.content[]?
         | if .type == "tool_use" then "  → " + .name
           elif .type == "text" then ("  " + (.text | gsub("\n"; "\n  ")))
           else empty end)
      # ── Codex events: item.* envelopes + turn.completed usage ──
      elif .type == "item.started" and .item.type? == "command_execution" then
        "  → exec: " + ((.item.command // "") | gsub("[\\n\\r]+"; " ⏎ ") | .[0:100])
      elif .type == "item.completed" then
        ( .item
          | if .type == "reasoning" then
              ((.text // empty) | tostring | "  ⋯ " + gsub("[\\n\\r]+"; "\n  ⋯ "))
            elif .type == "agent_message" then
              ((.text // empty) | tostring | "  " + gsub("\n"; "\n  "))
            elif .type == "command_execution" then empty
            else "  → " + .type end )
      elif .type == "turn.completed" then
        ( ((.usage.input_tokens // 0) + (.usage.output_tokens // 0))
          | select(. > 0)
          | if . >= 1000 then "        · turn done (" + (. / 1000 | floor | tostring) + "k tok)"
            else "        · turn done (" + tostring + " tok)" end )
      elif .type == "turn.failed" then
        "  ✖ turn failed" + ((.error.message? // empty) | tostring | if . == "" then "" else ": " + . end)
      else empty end' 2>/dev/null
  else
    cat
  fi
}

# Background guard for one agent session: kills the container when the log has
# been silent for STALL_MIN (a hung API call — the 504 stalls that otherwise
# burn hours). Total session length is deliberately NOT capped: a healthy long
# session keeps emitting events. The reason goes to $3; run_agent reads it
# after the pipeline ends.
agent_watchdog() {
  local name="$1" log="$2" flag="$3" now m
  while sleep 30; do
    docker inspect -f '{{.State.Running}}' "$name" >/dev/null 2>&1 || continue
    now="$(date +%s)"
    m="$(stat -f %m "$log" 2>/dev/null || stat -c %Y "$log" 2>/dev/null || echo "$now")"
    if (( STALL_MIN > 0 )) && (( now - m > STALL_MIN * 60 )); then
      echo "no output for ${STALL_MIN}m — model/API looks hung (--stall-timeout)" > "$flag"
      docker kill "$name" >/dev/null 2>&1; return 0
    fi
  done
}

stop_watchdog() {
  [[ -n "$WD_PID" ]] || return 0
  kill "$WD_PID" 2>/dev/null || true
  wait "$WD_PID" 2>/dev/null || true
  WD_PID=""
}

run_agent() {
  local prompt="$1" log wdflag
  log="logs/$(date +%Y%m%d-%H%M%S)-$ENGINE.jsonl"
  info "engine: $ENGINE"
  info "log: $log (full transcript; terminal shows tool calls only)"
  echo
  AGENT_SEQ=$(( AGENT_SEQ + 1 ))
  CONTAINER_NAME="agentloop-$RUN_ID-$AGENT_SEQ"
  wdflag="$(mktemp "${TMPDIR:-/tmp}/agentloop-wd.XXXXXX")"; : > "$wdflag"
  : > "$log"
  if (( STALL_MIN > 0 )); then
    agent_watchdog "$CONTAINER_NAME" "$log" "$wdflag" &
    WD_PID=$!
  fi

  if [[ "$ENGINE" == "claude" ]]; then
    # Headless Claude Code. bypassPermissions is safe for the same reason it
    # is for OpenCode: the container is the boundary. Deny rules in
    # .claude/settings.json still apply even in this mode.
    in_container claude -p "$prompt" \
      --permission-mode bypassPermissions \
      --output-format stream-json --verbose \
      ${MODEL:+--model "$MODEL"} | tee "$log" | stream_view
  elif [[ "$ENGINE" == "codex" ]]; then
    # Codex ships its own bubblewrap sandbox, which cannot start inside our
    # container. The container IS the sandbox here, so bypass Codex's — the
    # same reasoning as bypassPermissions for Claude Code.
    in_container codex exec --json \
      --dangerously-bypass-approvals-and-sandbox \
      ${MODEL:+-c "model=\"$MODEL\""} \
      "$prompt" | tee "$log" | stream_view
  elif (( HEADROOM )); then
    # Headroom: an in-container OpenAI-compatible proxy that compresses old
    # tool outputs (locally, reversibly) before they reach the model. OpenCode
    # is pointed at it via OPENCODE_CONFIG_CONTENT (a runtime override — the
    # project's opencode.json is untouched); the proxy forwards the
    # Authorization header to OpenRouter, so it needs no key of its own.
    info "headroom: compressing context via local proxy (profile: coding)"
    in_container bash -c '
      headroom proxy --host 127.0.0.1 --port 8787 \
        --openai-api-url https://openrouter.ai/api >/tmp/headroom.log 2>&1 &
      for _ in $(seq 1 40); do
        curl -sf http://127.0.0.1:8787/health >/dev/null 2>&1 && break; sleep 0.5
      done
      export OPENCODE_CONFIG_CONTENT="{\"provider\":{\"openrouter\":{\"options\":{\"baseURL\":\"http://127.0.0.1:8787/v1\"}}}}"
      exec "$@"' _ opencode run --format json ${MODEL:+-m "$MODEL"} "$prompt" | tee "$log" | stream_view
  else
    in_container opencode run --format json ${MODEL:+-m "$MODEL"} "$prompt" | tee "$log" | stream_view
  fi
  local rc=${PIPESTATUS[0]}
  stop_watchdog
  CONTAINER_NAME=""
  if [[ -s "$wdflag" ]]; then
    echo
    echo "  ✖ agent stopped by watchdog: $(cat "$wdflag")"
    rc=124
  fi
  rm -f "$wdflag"

  echo
  if command -v jq >/dev/null 2>&1 && [[ -s "$log" ]]; then
    echo "  tools used:"
    # OpenCode nests the payload under .part; Claude Code nests tool_use
    # blocks inside assistant messages.
    {
      jq -r 'select(.type=="tool_use") | .part.tool // .tool // .name // empty' "$log" 2>/dev/null
      jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="tool_use") | .name // empty' "$log" 2>/dev/null
      jq -r 'select(.type=="item.completed") | .item.type
             | select(. != "agent_message" and . != "reasoning")' "$log" 2>/dev/null
    } | sed 's/^/    /' | sort | uniq -c | sort -rn || true
    # Totals: OpenCode reports per-step tokens; Claude Code reports cost.
    jq -sr '[.[] | select(.type=="step_finish") | .part.tokens.total // 0] | add
            | select(. > 0) | "  session tokens: " + tostring' "$log" 2>/dev/null || true
    jq -sr '[.[] | select(.type=="turn.completed")
             | (.usage.input_tokens // 0) + (.usage.output_tokens // 0)] | add
            | select(. > 0) | "  session tokens: " + tostring' "$log" 2>/dev/null || true
    jq -r 'select(.type=="result") | .total_cost_usd? // empty
           | "  session cost: $" + (.|tostring)' "$log" 2>/dev/null | tail -1 || true
  fi
  return "$rc"
}

# Local evidence only — the agent commits inside the container, and the
# host's view of refs on a macOS bind mount can lag those writes, so a false
# negative here must never be treated as authoritative. GitHub (a PR existing
# for the branch) is the ground truth; this is the fallback diagnostic.
# Commits the AGENT made: counted from BRANCH_BASE, which new_work_branch and
# tick_item_on_branch move past the loop's own tick commit — otherwise that
# tick alone made every empty session look like "commits exist but no PR".
BRANCH_BASE=""
made_commits() { [[ -n "$(git log --oneline "${BRANCH_BASE:-origin/main}..HEAD" 2>/dev/null)" ]]; }
current_pr()   { gh_c pr view --json number -q .number 2>/dev/null; }
pr_labels()    { gh_c pr view "$1" --json labels -q '.labels[].name' 2>/dev/null || true; }

# Labels decide what GitHub does next — automerge acts only on "automated" and
# skips "blocked" and "plan" — so bash sets them instead of trusting the model
# to remember. Returns 1 when the agent asked for a human ("blocked", or
# "plan" on an item PR): nothing will merge such a PR, so waiting for it would
# only burn the merge timeout. Otherwise it makes sure "automated" is on (a
# no-op when present; when it was missing, the "labeled" event starts the
# automerge workflow right away).
PR_FLAG=""
ensure_automerge_label() {
  local pr="$1" labels
  labels="$(pr_labels "$pr")"
  PR_FLAG=""
  if grep -qx 'blocked' <<<"$labels"; then PR_FLAG="blocked"; return 1; fi
  if grep -qx 'plan' <<<"$labels";    then PR_FLAG="plan";    return 1; fi
  if ! grep -qx 'automated' <<<"$labels"; then
    if gh_c pr edit "$pr" --add-label automated >/dev/null 2>&1; then
      info "labelled PR #$pr 'automated' (the agent left the label off)"
    else
      info "could not label PR #$pr 'automated' — automerge will ignore it"
    fi
  fi
  return 0
}

# Shared stop for a PR the agent handed to a human.
stop_for_flagged_pr() {
  local pr="$1" url
  url="$(gh_c pr view "$pr" --json url -q .url 2>/dev/null || true)"
  echo
  if [[ "$PR_FLAG" == "blocked" ]]; then
    echo "STOPPING: the agent labelled PR #$pr 'blocked' — it got stuck and needs you."
  else
    echo "STOPPING: the agent labelled PR #$pr '$PR_FLAG' — it asked for a human review."
  fi
  echo "Read its description: ${url:-open it on GitHub}"
  keep_branch_and_return "PR needs a human" "$pr"
}

# Branch creation is deterministic work, so bash does it — the agent starts
# every session already on a fresh work branch and can never dirty main, even
# if it crashes mid-session or ignores the contract. (A weak model that still
# runs `git switch -c` on top of this merely branches off the safety branch;
# main stays untouched either way.)
new_work_branch() {
  local prefix="$1" text="${2:-}" slug branch
  slug="$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]' \
          | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-40)"
  branch="${prefix}${slug:+/$slug}-$(date +%m%d%H%M%S)"
  git switch -c "$branch" >/dev/null 2>&1 || die "could not create work branch $branch"
  WORK_BRANCH="$branch"
  BRANCH_BASE="$(git rev-parse HEAD 2>/dev/null || true)"
  info "work branch: $branch"
}
WORK_BRANCH=""

# Ticking is deterministic, so bash does it — models forget step 4 of an
# 8-step checklist after a million tokens of context. The tick is committed
# on the WORK BRANCH, so it keeps the property that matters: it reaches main
# only if the PR merges; a dead PR takes its tick to the grave.
tick_item_on_branch() {
  local item="$1" ln
  [[ -n "$item" && -f "$PLAN" ]] || return 0
  ln="$(grep -nF -- "- [ ] $item" "$PLAN" | head -1 | cut -d: -f1)"
  [[ -n "$ln" ]] || return 0
  sed -i.bak "${ln}s/- \[ \]/- [x]/" "$PLAN" && rm -f "$PLAN.bak"
  git add "$PLAN"
  git commit -q -m "chore: tick plan item (loop-managed; lands only when this PR merges)" || true
  BRANCH_BASE="$(git rev-parse HEAD 2>/dev/null || true)"
}

# After a failed/empty session, try to leave the repo back on a clean main.
# Only safe when the tree is clean; otherwise print exact cleanup commands —
# never destroy uncommitted work automatically.
abandon_work_branch() {
  [[ -n "$WORK_BRANCH" ]] || return 0
  if [[ -z "$(git status --porcelain 2>/dev/null)" ]]; then
    git switch main --quiet 2>/dev/null || true
    git branch -D "$WORK_BRANCH" >/dev/null 2>&1 || true
    info "cleaned up: back on main, removed $WORK_BRANCH"
  else
    # Uncommitted leftovers: never destroy them — park them and go back to main.
    keep_branch_and_return "the session left uncommitted changes"
  fi
}

# On any failed/aborted run: leave the checkout on a clean main (so ./run.sh
# can start again immediately) but KEEP the work branch for inspection, and say
# exactly how to look at it or throw it away. Leftover uncommitted changes are
# stashed (never discarded). Also used by the Ctrl+C handler.
keep_branch_and_return() {
  local why="${1:-}" pr="${2:-}" br stashed=""
  br="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  [[ -n "$br" && "$br" != "main" && "$br" != "master" && "$br" != "HEAD" ]] || return 0
  if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    git stash push -u -q -m "agentloop: leftovers from $br" >/dev/null 2>&1 && stashed=1
  fi
  echo
  if git switch main --quiet 2>/dev/null; then
    echo "  Back on main${why:+ ($why)} — the work branch is kept for inspection:"
    echo "    branch:    $br${pr:+   (PR #$pr)}"
    echo "    look at it:    git switch $br"
    echo "    throw it away: git branch -D $br${pr:+  &&  gh pr close $pr --delete-branch}"
    echo "    or just start again from main:  ./run.sh   (add --task \"...\" for a one-off)"
    [[ -n "$stashed" ]] && echo "    uncommitted leftovers were stashed:  git stash list   (restore on that branch: git stash pop)"
  else
    echo "  Could not switch back to main${why:+ ($why)}; still on $br."
    echo "  Check:  git status"
  fi
}

# Ctrl+C / kill: stop every container of this run first (a bare Ctrl+C can
# leave docker running in the background), then return to main.
kill_run_containers() {
  local ids
  ids="$(docker ps -q --filter "label=agentloop.run=$RUN_ID" 2>/dev/null || true)"
  # shellcheck disable=SC2086
  [[ -n "$ids" ]] && docker kill $ids >/dev/null 2>&1
  return 0
}
on_interrupt() {
  trap '' INT TERM
  echo
  echo "  interrupted — stopping the agent container..."
  stop_watchdog
  kill_run_containers
  keep_branch_and_return "interrupted"
  exit 130
}
cleanup_exit() {
  stop_watchdog
  kill_run_containers
  [[ -n "$SNAP" ]] && rm -f "$SNAP"
  [[ -n "$SKILLSNAP" ]] && rm -f "$SKILLSNAP"
  return 0
}

# Poll until the PR merges, CI fails, or we time out. No agent turns, no
# tokens burned — containerized gh calls only.
#
# CI verdict comes from the Actions API (workflow runs for the PR's head
# commit), NOT from check runs: GitHub does not offer the "Checks" permission
# on fine-grained PATs, so check-run data is invisible to the agent token.
# Workflow runs are readable with "Actions: Read-only".
RERUN_DONE=""
CIDBG=/dev/null
wait_for_merge() {
  local pr="$1" deadline=$(( $(date +%s) + TIMEOUT_MIN * 60 ))
  local first_fail=0 told=0
  echo "> waiting for PR #$pr to merge (timeout ${TIMEOUT_MIN}m)"
  while (( $(date +%s) < deadline )); do
    local out state head
    out="$(gh_c pr view "$pr" --json state,headRefOid \
          -q '[.state, .headRefOid] | join(" ")' 2>/dev/null || true)"
    state="${out%% *}"
    head="${out##* }"
    [[ -z "$state" ]] && state="UNKNOWN"
    case "$state" in
      MERGED) info "merged"; return 0 ;;
      CLOSED) info "PR was closed without merging"; return 2 ;;
    esac
    if [[ -n "$head" && "$head" != "$state" ]]; then
      local runs fails=0 pending=0 rid rname rstatus rconc
      runs="$(gh_c api "repos/{owner}/{repo}/actions/runs?head_sha=$head&per_page=30" \
        --jq '.workflow_runs[] | select(.name != "automerge") | [.id, .name, .status, (.conclusion // "")] | @tsv' \
        2>/dev/null || true)"
      while IFS=$'\t' read -r rid rname rstatus rconc; do
        [[ -n "$rid" ]] || continue
        if [[ "$rstatus" != "completed" ]]; then pending=$(( pending + 1 )); continue; fi
        case "$rconc" in
          failure|timed_out) fails=$(( fails + 1 )) ;;
          cancelled)
            # GitHub sometimes cancels runs on its own. Re-run each once.
            if [[ " $RERUN_DONE " != *" $rid "* ]]; then
              RERUN_DONE="$RERUN_DONE $rid"
              if gh_c run rerun "$rid" >/dev/null 2>&1; then
                info "run $rid ($rname) was cancelled — re-running it"
                pending=$(( pending + 1 ))
              else
                fails=$(( fails + 1 ))
              fi
            else
              fails=$(( fails + 1 ))
            fi ;;
        esac
      done <<< "$runs"
      # A failure is only reported once every other check has finished (or 15
      # minutes passed), so the agent gets the logs of ALL failed jobs — e.g.
      # the Windows job, not just whichever failed first.
      if (( fails > 0 )); then
        (( first_fail )) || first_fail="$(date +%s)"
        if (( pending == 0 )) || (( $(date +%s) - first_fail > 900 )); then
          info "CI failed on PR #$pr (failed runs: $fails, still running: $pending)"
          return 3
        fi
        if (( ! told )); then
          info "a check failed — waiting for the remaining checks to finish"
          told=1
        fi
      fi
    fi
    sleep 20
  done
  info "timed out waiting for PR #$pr"
  return 1
}

# Fetch the tail of the failing CI log for a PR's head commit — readable with
# the agent token's "Actions: Read-only" permission.
# Strip the per-line "job<TAB>step<TAB>timestamp " prefix that `gh run view
# --log-failed` adds and cut everything from "Post job cleanup." on — on
# Windows that cleanup is ~16 lines of git noise that would push the actual
# compiler error out of a tail window.
_clean_job_log() {
  awk -F'\t' '{
    line = $0
    if (NF >= 3) { line = $3; for (i = 4; i <= NF; i++) line = line "\t" $i }
    sub(/^[0-9T:.-]+Z /, "", line)
    if (line ~ /^Post job cleanup\./) exit
    print line
  }' | tail -60
}

# One pass over the failing runs of the PR head. Every gh error goes to $CIDBG
# (never swallowed): an empty result is otherwise indistinguishable from "no
# failure found", which is exactly the failure mode that hid CI logs before.
_ci_fail_log_once() {
  local pr="$1" head runs rid rname jobs jid jname out n=0 k
  head="$(gh_c pr view "$pr" --json headRefOid -q .headRefOid 2>>"$CIDBG" || true)"
  echo "head=$head" >> "$CIDBG"
  [[ -n "$head" ]] || { echo "no head sha for PR #$pr" >> "$CIDBG"; return 0; }
  runs="$(gh_c api "repos/{owner}/{repo}/actions/runs?head_sha=$head&per_page=30" \
        --jq '.workflow_runs[] | select(.name != "automerge") | select(.conclusion=="failure" or .conclusion=="timed_out" or .conclusion=="cancelled") | [.id, .name] | @tsv' \
        2>>"$CIDBG" || true)"
  echo "failed runs: ${runs:-<none>}" >> "$CIDBG"
  [[ -n "$runs" ]] || return 0
  while IFS=$'\t' read -r rid rname; do
    [[ -n "$rid" ]] || continue
    jobs="$(gh_c run view "$rid" --json jobs \
          --jq '.jobs[] | select(.conclusion=="failure" or .conclusion=="timed_out") | [.databaseId, .name] | @tsv' \
          2>>"$CIDBG" || true)"
    echo "run $rid jobs: ${jobs:-<none>}" >> "$CIDBG"
    if [[ -z "$jobs" ]]; then
      echo "### workflow \"$rname\" (run $rid) did not finish — no failed job recorded (cancelled/timed out)"
      continue
    fi
    while IFS=$'\t' read -r jid jname; do
      [[ -n "$jid" ]] || continue
      n=$(( n + 1 )); (( n > 4 )) && break
      echo "### FAILED JOB: $rname / $jname"
      # Log archives lag behind the failure conclusion — retry briefly.
      out=""
      for k in 1 2 3; do
        out="$(gh_c run view --job "$jid" --log-failed 2>>"$CIDBG" | _clean_job_log)"
        [[ -n "$out" ]] && break
        echo "job $jid: log empty on try $k" >> "$CIDBG"
        sleep 10
      done
      printf '%s\n' "${out:-<log not available yet>}"
    done <<< "$jobs"
  done <<< "$runs"
}

# The failing-CI log for a PR's head commit, readable with the agent token's
# "Actions: Read-only" permission. Retried as a whole (GitHub's run/job lists
# can lag the failure by a few seconds), with a trace of every step written to
# logs/<ts>-cifail.txt so an empty result can be diagnosed afterwards. The
# status line goes to stderr: stdout is the log itself.
ci_fail_log() {
  local pr="$1" out="" attempt
  mkdir -p logs
  CIDBG="logs/$(date +%Y%m%d-%H%M%S)-cifail.txt"
  : > "$CIDBG"
  for attempt in 1 2 3; do
    out="$(_ci_fail_log_once "$pr")"
    [[ -n "$out" ]] && break
    echo "attempt $attempt: empty result" >> "$CIDBG"
    sleep 15
  done
  if [[ -n "$out" ]]; then
    info "CI log captured: $(printf '%s\n' "$out" | wc -l | tr -d ' ') lines (trace: $CIDBG)" >&2
  else
    info "CI log EMPTY after 3 tries — see $CIDBG" >&2
  fi
  printf '%s\n' "$out"
}

prompt_ci_fix() {
cat <<EOF
CI failed on pull request #$2, which implements this plan item:

    $1

$(skill_load_line agentloop-ci-fix)
You are already on the PR's branch. Stay on it — do not create a new branch
and do not touch main. PLAN.md on this branch may already show the item as
[x] — that is expected (an earlier session ticked it; the tick only reaches
main if this PR merges). Do NOT modify PLAN.md in this session, with one
exception: if you merge main into this branch and PLAN.md conflicts, resolve
by taking MAIN's version of every line except this PR's own item, which
keeps its [x]. Never let a conflict resolution untick someone else's item.
Do this:

1. Diagnose the failure from the log below; it lists every failed job. If the
   log is missing or unclear, do NOT dig through git history or PR metadata —
   open EVERY workflow in .github/workflows/ (not only ci.yml) and run the
   check commands they define (lint, format check, type check, tests), in
   order, exactly as written there. That is the fastest reproduction.
   Platform note: this container is Linux. If a failed job runs on windows or
   macos (or a different toolchain, e.g. an MSRV/minimum-version job), the
   failure usually will NOT reproduce here — do not conclude "all green, no
   fix needed". Fix it directly from the log: typically platform-specific code
   or imports (and their tests) missing a platform guard such as
   #[cfg(unix)] / sys.platform checks, path-separator or line-ending
   assumptions, or APIs newer than the minimum supported version.
2. Fix the CODE. Never weaken, skip or delete tests to get green. If a
   lockfile check failed, regenerate the lockfile with the project's
   dependency tool (e.g. uv lock) and commit it.
3. Run the project's lint and test commands locally until they pass.
4. Commit and push to this same branch — the existing PR updates itself.
5. Stop. Do not merge, do not start anything else.

--- FAILING CI LOG (per failed job; tail) ---
$3
--- END LOG ---
EOF
}

# Wait for a PR to merge; on CI failure, feed the failing log back to the
# agent on the same branch and retry — bounded by --ci-retries. Bash fetches
# the log and switches branches (deterministic work); the model only fixes
# code. Result in AWAIT_RC (wait_for_merge codes), attempts in AWAIT_FIXES.
AWAIT_RC=1
AWAIT_FIXES=0
await_merge_and_autofix() {
  local pr="$1" desc="$2" fb faillog
  AWAIT_FIXES=0
  while :; do
    wait_for_merge "$pr"
    AWAIT_RC=$?
    [[ "$AWAIT_RC" != "3" ]] && return 0
    if (( AWAIT_FIXES >= CI_RETRIES )); then return 0; fi
    AWAIT_FIXES=$((AWAIT_FIXES + 1))
    echo
    rule
    echo "CI failed on PR #$pr — automatic fix attempt $AWAIT_FIXES/$CI_RETRIES"
    rule
    fb="$(gh_c pr view "$pr" --json headRefName -q .headRefName 2>/dev/null || true)"
    if [[ -z "$fb" ]] || ! git switch "$fb" --quiet 2>/dev/null; then
      echo "  could not switch to the PR branch — leaving it to you."
      return 0
    fi
    faillog="$(ci_fail_log "$pr")"
    run_agent "$(prompt_ci_fix "$desc" "$pr" "${faillog:-<log unavailable — reproduce locally>}")"
  done
}

# Show the "- [ ]" lines that appeared in PLAN.md during this iteration.
show_plan_additions() {
  local before="$1"
  [[ -f "$before" && -f "$PLAN" ]] || return 0
  local added
  added="$(diff <(grep -E '^[[:space:]]*- \[ \]' "$before" 2>/dev/null) \
                <(grep -E '^[[:space:]]*- \[ \]' "$PLAN"   2>/dev/null) \
           | sed -n 's/^> *//p')"
  [[ -z "$added" ]] && return 0
  echo "  the agent added to the plan:"
  printf '%s\n' "$added" | sed -E 's/^[[:space:]]*- \[ \][[:space:]]*/    + /'
}

# Skills that reached main with this merge: the loop's memory growing. Shown
# like plan additions, so a human sees (and can prune) what sessions record.
show_new_skills() {
  local before="$1" added f
  [[ -f "$before" ]] || return 0
  added="$(skills_list | comm -13 "$before" - 2>/dev/null)"
  [[ -n "$added" ]] || return 0
  echo "  the agent recorded a skill for later sessions:"
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    SKILLS_ADDED=$(( SKILLS_ADDED + 1 ))
    printf '    + %s — %s\n' "$(basename "$(dirname "$f")")" \
      "$(skill_field "$f" description | cut -c1-90)"
  done <<< "$added"
}

# ── Prompt fragments ─────────────────────────────────────────────────────────
# "Load the skill X first ..." when X is installed; nothing otherwise.
skill_load_line() {
  [[ -f "$SKILLS_DIR/$1/SKILL.md" ]] || return 0
  printf 'Load the skill %s first (%s/%s/SKILL.md) and follow it.\n' "$1" "$SKILLS_DIR" "$1"
}

# Sessions may leave the next session a project skill — the loop's memory.
learn_clause() {
  if (( ! LEARN )); then
    echo "Do not create or modify skills in $SKILLS_DIR/ in this session."
    return
  fi
  cat <<EOF
If you worked out something non-obvious and reusable about this project — how
   to run, test, debug or seed part of it, or a trap that cost you attempts —
   record it as a project skill in $SKILLS_DIR/<name>/SKILL.md so the next
   session does not rediscover it (skill agentloop-skill-authoring). At most
   one new skill; never touch agentloop-* skills; name it in the PR description.
EOF
}

discovery_clause() {
  (( DISCOVER )) || { echo "Do not add, remove or reword any item in PLAN.md. You may only tick your own item."; return; }
cat <<'EOF'
While doing this, you may discover work that the project genuinely needs and
PLAN.md does not cover — a missing edge case, a required migration, a piece of
error handling, a refactor a later item will depend on. Record it:

  - Append new "- [ ]" items to the END of the milestone they belong to, or
    under "## Discovered" if you are not sure where they fit.
  - At most 3 new items. If you found nothing, add nothing — do not pad the
    plan to look productive.
  - Write them in the same style as existing items: concrete, independently
    testable, one pull request each.
  - APPEND ONLY. Never delete, reorder, reword or uncheck an existing item,
    and never edit an item above the one you are working on.
  - List what you added and why in the PR description.

If you discover something that must be done BEFORE your current item can work,
do not reorder the plan. Stop, open the PR with the "blocked" label, and explain
the dependency.
EOF
}

prompt_init() {
cat <<EOF
You are bootstrapping a new project. Here is the description:

--- BEGIN DESCRIPTION ---
$ARG_TEXT
--- END DESCRIPTION ---

Your job in this session is ONLY to produce the plan. Do not implement features.

0. You are already on a fresh work branch created for this session. Stay on
   it — do not switch branches and do not touch main.

1. Create PLAN.md in exactly this format:

    # Plan

    ## Milestone 1: <name>
    - [ ] <one self-contained, testable step>
    - [ ] <another step>

    ## Milestone 2: <name>
    - [ ] <step>

    ## Discovered
    <!-- work found while building; appended by the agent -->

   Rules for the plan:
   - Every item must be small enough to finish in one pull request.
   - Every item must be independently testable.
   - Order items so each one only depends on items above it.
   - Write items as instructions, not topics: "Add config loading from
     environment variables with validation", not "Config".
   - An item may carry details: lines indented by two spaces right under it
     (constraints, edge cases, acceptance criteria). The session that works
     on the item receives them. Never indent a "- [ ]" line under an item.
   - Aim for 8 to 20 items. Do not plan the whole product; plan the first
     working version. You will be able to add more as you build.
   $(skill_load_line agentloop-plan-items)

2. Create the minimum scaffolding the plan needs: project layout, dependency
   manifest, a placeholder test so the test command passes, and a README with
   a one-paragraph summary.

3. Fill in the "Project reference" section at the bottom of AGENTS.md with the
   real test, lint and dependency commands for this project.

4. Commit with a message starting "chore: ", push, and open a PR with:
     gh pr create --fill --label plan
   Use the label "plan", NOT "automated" — a human reviews the plan.

5. Stop. Do not implement any plan item.
EOF
}

prompt_replan() {
skill_load_line agentloop-plan-items
cat <<'EOF'
Audit the repository against PLAN.md and correct the plan. Do not implement
features in this session.

0. You are already on a fresh work branch created for this session. Stay on
   it — do not switch branches and do not touch main.

1. For each item in PLAN.md, check whether it is actually done in the code.
   Fix the checkboxes so they reflect reality.
2. Promote anything under "## Discovered" into the milestone where it belongs,
   in dependency order.
3. Add items that are clearly needed but missing.
4. Split any remaining item that is too large for one pull request.
5. Delete items that are no longer relevant, and say why in the commit message.
6. Enforce the canonical format: "## Milestone N: name" headings,
   "- [ ]" / "- [x]" items, and a "## Discovered" section at the end.
   If PLAN.md is currently written in ANY other style — status tables, prose,
   bare [x] lines, emoji markers — rewrite it into this format, preserving
   every item's meaning and done/not-done status. The loop can only parse
   "- [ ]" lines, so anything else is invisible to it. Details indented two
   spaces under an item are allowed and are handed to the session doing it —
   add them where an item's constraints or acceptance criteria are unclear.
7. Project skills in .agents/skills/ (everything except agentloop-*): fix or
   delete any that are stale, wrong or duplicated, and say why.
8. Commit with a message starting "chore: ", push, and open a PR with:
     gh pr create --fill --label plan
9. Stop.

This is the one session where you are allowed to restructure PLAN.md freely.
EOF
if (( AMBITIOUS )); then
cat <<'EOF'

ADDITIONALLY — vision pass (you are explicitly NOT conservative here):
Study this project as a PRODUCT, not a codebase. Think about who uses it and
what they would miss most: compare against the obvious alternatives in its
domain, read the README promises, look for capabilities that stop halfway.
Then add a new milestone at the end of PLAN.md:

    ## Milestone N: Proposed Features (vision)

with 5-10 genuinely NEW feature items — not cleanups, not test coverage, not
refactors. Rules for these items:
- each must be a capability a real user would notice and value
- each must be implementable in this codebase and sized for 1-3 pull requests
- each must state a verifiable outcome (a test, a demo command, a doc)
- do NOT implement any of them in this session

The human reviews this PR and deletes what they don't want — propose boldly,
they can prune. An empty vision section is a failure of imagination, not
caution.
EOF
fi
}

prompt_item() {
cat <<EOF
Your task for this session is exactly this item from PLAN.md:

    $1

EOF
  if [[ -n "${2:-}" ]]; then
    echo "Details and acceptance criteria (from PLAN.md — part of the item):"
    printf '%s\n' "$2" | sed 's/^/    /'
    echo
  fi
  graph_section "${3:-}"
cat <<EOF
Do this:

0. You are already on a fresh work branch created for this session — stay on
   it. Skip any "create a branch" step; never switch to or touch main.
1. Implement only that item. Do not start any other item and do not refactor
   unrelated code.
2. Write or extend tests that prove it works.
3. Run the project's lint and test commands. Fix failures until green.
4. PLAN.md on this branch already shows the item as "- [x]" — the loop
   ticked it when it created the branch. Leave it. Only if you finish this
   session WITHOUT completing the item, revert it to "- [ ]".
5. $(discovery_clause)
6. $(learn_clause)
7. Follow the workflow in AGENTS.md: branch, commit, push, and open a pull
   request with the "automated" label.
8. Stop. Do not wait for CI, do not merge, do not start the next item.
EOF
  local skills
  skills="$(skills_present agentloop-graph-navigation agentloop-testing agentloop-pull-request)"
  if [[ -n "$skills" ]]; then
    printf '\nSkills that usually matter here (%s/<name>/SKILL.md — load each when it applies): %s.\n' \
      "$SKILLS_DIR" "$skills"
  fi
}

# Replan is used both as a standalone mode and by --auto-replan when the plan
# runs out mid-loop. Opens a plan-labelled PR (never auto-merged) and stops.
do_replan() {
  rule; echo "MODE: replan — auditing PLAN.md against the code"; rule
  graph_sync
  new_work_branch "chore/replan" ""
  run_agent "$(prompt_replan)"
  local rc=$? rp rp_url
  rp="$(current_pr || true)"
  if [[ -n "$rp" ]]; then
    rp_url="$(gh_c pr view "$rp" --json url -q .url 2>/dev/null || true)"
    echo
    echo "Plan PR #$rp opened: ${rp_url:-see it on GitHub}"
    echo "Review and merge it yourself — plan PRs never auto-merge."
  else
    made_commits || abandon_work_branch
  fi
  return "$rc"
}

# ── One-shot modes ───────────────────────────────────────────────────────────
trap on_interrupt INT TERM
trap cleanup_exit EXIT

case "$MODE" in
  reindex)
    graph_sync force; exit 0 ;;
  ghsetup)
    rule; echo "MODE: github-setup — configuring the repo from inside the container"; rule
    [[ -f "$REPO_DIR/setup-github.sh" ]] || die "setup-github.sh not found in $REPO_DIR"
    # CHECK empty = setup-github.sh auto-detects from the checks on main
    in_container env AGENTLOOP_YES=1 CHECK="${CHECK:-}" bash ./setup-github.sh
    exit $? ;;
  init)
    [[ -n "$ARG_TEXT" ]] || die "--init needs a description (text or -f file)"
    rule; echo "MODE: init — drafting PLAN.md"; rule
    graph_sync
    new_work_branch "chore/plan-draft" ""
    run_agent "$(prompt_init)"; rc=$?
    pr="$(current_pr || true)"
    [[ -n "$pr" ]] || made_commits || abandon_work_branch
    echo
    if [[ -n "$pr" ]] || made_commits; then
      pr_url="$(gh_c pr view "${pr:-}" --json url -q .url 2>/dev/null || true)"
      echo "PLAN.md drafted${pr:+ in PR #$pr}."
      echo
      echo "Review it and merge it yourself: ${pr_url:-open the PR on GitHub}"
      echo "The plan is the one thing worth your review — a bad plan becomes"
      echo "twenty bad pull requests, and by then it is expensive to undo."
    else
      echo "No commits were made. Check the log above."
    fi
    exit "$rc" ;;
  replan)
    do_replan; exit $? ;;
  task)
    [[ -n "$ARG_TEXT" ]] || die "--task needs text"
    rule; echo "MODE: task — one-off"; rule
    # If we're already on a feature branch, tell the agent to stay on it.
    # Otherwise AGENTS.md's "always create a branch" rule would make a weak
    # model open a SECOND branch/PR instead of updating the existing one —
    # exactly wrong for the "fix CI on this PR" flow.
    TASK_TEXT="$ARG_TEXT"
    cur_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
    if [[ "$cur_branch" != "main" && "$cur_branch" != "master" ]]; then
      ARG_TEXT="$ARG_TEXT

NOTE: you are already on branch '$cur_branch', which has an open pull request.
Stay on THIS branch — do not create a new one. Commit and push here so the
existing PR updates. The 'create a branch' step in AGENTS.md does not apply."
      info "on branch '$cur_branch' — agent will update the existing PR"
    fi
    graph_sync
    graphctx="$(graph_context "$TASK_TEXT")"
    if [[ "$cur_branch" == "main" || "$cur_branch" == "master" ]]; then
      new_work_branch "task" "$TASK_TEXT"
    fi
    BRANCH_BASE="$(git rev-parse HEAD 2>/dev/null || true)"
    task_prompt="$ARG_TEXT"
    if [[ -n "$graphctx" ]]; then
      task_prompt="$ARG_TEXT

$(graph_section "$graphctx")"
    fi
    run_agent "$task_prompt"; rc=$?
    pr="$(current_pr || true)"
    if [[ -z "$pr" ]] && ! made_commits; then
      echo "  no PR opened, no commits visible — the agent wrote nothing"
      abandon_work_branch
      exit "$rc"
    fi
    git log --oneline origin/main..HEAD 2>/dev/null | sed 's/^/  /'
    if [[ -n "$pr" ]]; then
      info "PR #$pr opened"
      if ! ensure_automerge_label "$pr"; then
        if (( WAIT )); then stop_for_flagged_pr "$pr"; exit 1; fi
        info "PR #$pr is labelled '$PR_FLAG' — it needs a human"
      fi
      if (( WAIT )); then
        await_merge_and_autofix "$pr" "$ARG_TEXT"
        case "$AWAIT_RC" in
          0) head_branch="$(gh_c pr view "$pr" --json headRefName -q .headRefName 2>/dev/null || true)"
             git switch main --quiet 2>/dev/null || true
             git_pull_c
             [[ -n "$head_branch" ]] && git branch -D "$head_branch" >/dev/null 2>&1 || true
             info "merged — back on main" ;;
          3) echo
             echo "CI is still failing on PR #$pr after $AWAIT_FIXES automatic fix attempt(s)."
             fb="$(gh_c pr view "$pr" --json headRefName -q .headRefName 2>/dev/null || true)"
             keep_branch_and_return "CI failing" "$pr"
             echo "  Take over:  git switch ${fb:-<branch>}  &&  ./run.sh --task \"<what to fix>\"" ;;
          *) pu="$(gh_c pr view "$pr" --json url -q .url 2>/dev/null || true)"
             echo "PR #$pr did not merge yet: ${pu:-open it on GitHub}"
             keep_branch_and_return "PR did not merge" "$pr" ;;
        esac
      else
        info "--no-wait: not waiting for the merge (automerge lands it when CI is green)"
      fi
    fi
    exit "$rc" ;;
esac

# ── Plan loop ────────────────────────────────────────────────────────────────
# Portable template form: BSD mktemp accepts `-t prefix`, GNU mktemp rejects
# it ("too few X's") — this spelling works on macOS and Linux alike.
SNAP="$(mktemp "${TMPDIR:-/tmp}/agentloop-planbefore.XXXXXX")"
SKILLSNAP="$(mktemp "${TMPDIR:-/tmp}/agentloop-skillsbefore.XXXXXX")"

completed_n=0
total_added=0

for (( i = 1; i <= COUNT; i++ )); do
  git switch main --quiet 2>/dev/null || true
  git_pull_c

  before_remaining="$(plan_remaining)"
  before_done="$(plan_done_count)"
  cp "$PLAN" "$SNAP" 2>/dev/null || true
  skills_list > "$SKILLSNAP" 2>/dev/null || true

  if [[ "$before_remaining" -eq 0 ]]; then
    echo
    if [[ "$(plan_done_count)" -eq 0 ]]; then
      # No unchecked AND no checked items: the file isn't empty of work,
      # it's in a format the loop cannot parse.
      echo "PLAN.md contains no '- [ ]' checklist items at all."
      echo "If your plan is written in another style (status tables, prose,"
      echo "bare [x] lines), the loop cannot see it. Convert it with:"
      echo "  ./run.sh --replan"
      echo "That mode rewrites the plan into the canonical format, preserving"
      echo "every item and its status, via a 'plan'-labelled PR you review."
    else
      echo "PLAN.md is complete — nothing left to do."
      if (( AUTO_REPLAN )); then
        echo "--auto-replan: having the agent propose the next wave..."
        echo
        do_replan
      else
        echo "Have the agent propose the next wave:  ./run.sh --replan"
        echo "(it audits the code, adds what's clearly missing, opens a plan PR"
        echo "for your review) — or add items yourself, or set AUTO_REPLAN=1 in"
        echo ".agentloop.local to do this automatically."
      fi
    fi
    break
  fi

  item="$(plan_next)"
  details="$(plan_details)"
  echo
  rule
  printf 'TASK %d/%s   ·   %s remaining\n' "$i" \
    "$([[ "$COUNT" -ge 9999 ]] && echo all || echo "$COUNT")" "$before_remaining"
  echo "$item"
  [[ -n "$details" ]] && printf '%s\n' "$details" | sed 's/^/  /'
  rule

  graph_sync
  graphctx="$(graph_context "$item")"
  [[ -n "$graphctx" ]] && info "graph: prompt seeded with $(printf '%s\n' "$graphctx" | wc -l | tr -d ' ') lines of context"
  new_work_branch "agent" "$item"
  tick_item_on_branch "$item"
  run_agent "$(prompt_item "$item" "$details" "$graphctx")"

  # Verify against GitHub first: a PR for this branch = work definitely
  # happened, whatever the local ref view claims.
  pr="$(current_pr || true)"
  if [[ -z "$pr" ]]; then
    if ! made_commits; then
      echo
      echo "STOPPING: no PR was opened and no commits are visible. The model"
      echo "may be failing at tool calls — look at the tool list above. If"
      echo "there are no 'bash' calls, change the model in opencode.json."
      abandon_work_branch
      exit 1
    fi
    echo
    echo "STOPPING: commits exist but no pull request was opened."
    keep_branch_and_return "no PR was opened"
    echo "  To retry: push the branch and open the PR yourself, or delete it and re-run."
    exit 1
  fi
  info "PR #$pr opened"
  if ! ensure_automerge_label "$pr"; then
    if (( WAIT )); then stop_for_flagged_pr "$pr"; exit 1; fi
    info "PR #$pr is labelled '$PR_FLAG' — it needs a human (continuing: --no-wait)"
  fi

  if (( ! WAIT )); then
    info "--no-wait: continuing without waiting for the merge"
    info "note: PLAN.md on main is stale, so the next item may repeat"
    continue
  fi

  await_merge_and_autofix "$pr" "$item"
  case "$AWAIT_RC" in
    0) : ;;
    3) fb="$(gh_c pr view "$pr" --json headRefName -q .headRefName 2>/dev/null || echo '<branch>')"
       echo
       echo "STOPPING: CI is still failing on PR #$pr after $AWAIT_FIXES automatic fix attempt(s)."
       keep_branch_and_return "CI failing" "$pr"
       echo "  Take over on the same branch:"
       echo "    git switch $fb"
       echo "    ./run.sh --task \"<what to fix>\""
       exit 1 ;;
    *) pu="$(gh_c pr view "$pr" --json url -q .url 2>/dev/null || true)"
       echo
       echo "STOPPING: PR #$pr did not merge. Take a look: ${pu:-open it on GitHub}"
       keep_branch_and_return "PR did not merge" "$pr"
       exit 1 ;;
  esac

  # ── Accounting: did it tick its box, and did the plan grow? ───────────────
  head_branch="$(gh_c pr view "$pr" --json headRefName -q .headRefName 2>/dev/null || true)"
  git switch main --quiet 2>/dev/null || true
  if ! git_pull_verified; then
    echo
    echo "WARNING: could not pull main after the merge (network?). Skipping the"
    echo "plan accounting rather than reading a stale PLAN.md — the merge itself"
    echo "succeeded. Run 'git pull' and start the loop again."
    exit 1
  fi
  # Remote branch is deleted by delete-branch-on-merge; tidy the local copy too.
  [[ -n "$head_branch" ]] && git branch -D "$head_branch" >/dev/null 2>&1 || true

  # Ticks must never regress: anything done before this iteration must still
  # be done. A revert here almost always means the PR's branch was stale and
  # a PLAN.md merge conflict got resolved against main.
  if [[ -f "$SNAP" ]]; then
    reverted="$(comm -23 <(grep -E '^[[:space:]]*- \[[xX]\]' "$SNAP" | sort) \
                         <(grep -E '^[[:space:]]*- \[[xX]\]' "$PLAN" | sort) 2>/dev/null || true)"
    if [[ -n "$reverted" ]]; then
      echo
      echo "WARNING: previously ticked item(s) were REVERTED by this merge —"
      echo "almost certainly a PLAN.md merge conflict resolved wrongly on a"
      echo "stale branch. The code for these is already on main; restore the"
      echo "ticks (edit PLAN.md on main, commit, push) before continuing:"
      printf '%s\n' "$reverted" | sed 's/^/    /'
      exit 1
    fi
  fi

  after_remaining="$(plan_remaining)"
  after_done="$(plan_done_count)"
  ticked=$(( after_done - before_done ))
  added=$(( after_remaining - before_remaining + ticked ))

  if (( ticked < 1 )); then
    echo
    echo "WARNING: the item was not ticked off in PLAN.md, so the next"
    echo "iteration would pick it up again. Tick it yourself, or stop and"
    echo "check whether the model is following AGENTS.md."
    exit 1
  fi

  completed_n=$(( completed_n + ticked ))
  if (( added > 0 )); then
    total_added=$(( total_added + added ))
    show_plan_additions "$SNAP"
  fi
  show_new_skills "$SKILLSNAP"

  if (( total_added > MAX_GROWTH )); then
    echo
    echo "STOPPING: the agent has added $total_added items this run, over the"
    echo "--max-growth limit of $MAX_GROWTH. The plan is growing faster than it"
    echo "shrinks, which usually means the items are too broad or the model is"
    echo "padding. Prune it with:"
    echo "  ./run.sh --replan"
    echo "or run with --no-discover to stop it adding anything."
    exit 1
  fi
done

git switch main --quiet 2>/dev/null || true
git_pull_c

echo
rule
echo "completed:     $completed_n item(s)"
echo "added to plan: $total_added item(s)"
if (( SKILLS_ADDED > 0 )); then echo "skills:        $SKILLS_ADDED recorded (./run.sh --skills to review)"; fi
echo "plan:          $(plan_done_count) done, $(plan_remaining) remaining"
n="$(plan_next || true)"
# An if, not `[[ ]] && echo`: as the script's last command, a false test
# made a fully successful run that finished the plan exit with status 1.
if [[ -n "${n:-}" ]]; then echo "next:          $n"; fi
exit 0
