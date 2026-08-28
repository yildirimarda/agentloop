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
TIMEOUT_MIN=20
MODEL=""
USE_GRAPH=1
DISCOVER=1
MAX_GROWTH=10
ARG_TEXT=""
ANTHROPIC_KEY=""

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
      --reindex             rebuild the Graphify knowledge graph from scratch
      --github-setup        run setup-github.sh inside the container using the
                            "gh-admin" keychain token (no host gh login needed)

Options
  -e, --engine NAME         opencode (default; free OpenRouter models) or
                            claude (paid; Claude Code + Anthropic API key)
      --no-discover         forbid the agent from adding items to PLAN.md
      --max-growth N        abort if the plan grows by more than N items
                            over this run (default 10)
      --no-wait             don't wait for the PR to merge before the next item
      --timeout N           minutes to wait for a merge (default 20)
  -m, --model ID            override the model from opencode.json
      --no-graph            skip the Graphify index step
      --image NAME          container image (default "agent")
  -h, --help                this

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
    --reindex)      MODE="reindex"; shift ;;
    --github-setup) MODE="ghsetup"; shift ;;
    -f|--file)      f="${2:?-f needs a path}"
                    [[ -f "$f" ]] || { echo "error: file not found: $f" >&2; exit 1; }
                    ARG_TEXT="$(cat "$f")"; shift 2 ;;
    -e|--engine)    ENGINE="${2:?--engine needs opencode or claude}"; shift 2 ;;
    --no-discover)  DISCOVER=0; shift ;;
    --max-growth)   MAX_GROWTH="${2:?--max-growth needs a number}"; shift 2 ;;
    --no-wait)      WAIT=0; shift ;;
    --timeout)      TIMEOUT_MIN="${2:?--timeout needs minutes}"; shift 2 ;;
    -m|--model)     MODEL="${2:?-m needs a model id}"; shift 2 ;;
    --no-graph)     USE_GRAPH=0; shift ;;
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

keychain() {
  security find-generic-password -s "$1" -w 2>/dev/null \
    || die "keychain entry '$1' not found. Add it with:
  security add-generic-password -s $1 -a \"\$USER\" -w '<secret>'"
}

case "$ENGINE" in
  opencode|claude) : ;;
  *) die "unknown engine: '$ENGINE' (use opencode or claude)" ;;
esac

# ── Dry run ──────────────────────────────────────────────────────────────────
if [[ "$MODE" == "next" ]]; then
  [[ -f "$PLAN" ]] || die "$PLAN not found. Bootstrap it:  ./run.sh --init \"<description>\""
  n="$(plan_next)" || true
  echo "done:      $(plan_done_count)"
  echo "remaining: $(plan_remaining)"
  echo "next:      ${n:-<nothing left>}"
  if [[ "$(plan_done_count)" -eq 0 && "$(plan_remaining)" -eq 0 ]]; then
    echo
    echo "note: no '- [ ]' items found. If PLAN.md uses another format"
    echo "(tables, prose, bare [x] lines), convert it:  ./run.sh --replan"
  fi
  exit 0
fi

# ── Cheap guards before any heavy checks ─────────────────────────────────────
if [[ "$MODE" == "init" && -f "$PLAN" ]]; then
  die "$PLAN already exists — refusing to overwrite it.
Use ./run.sh --replan to restructure it, or delete the file first if you
really want a fresh start."
fi

# ── Preflight ────────────────────────────────────────────────────────────────
# Note: no host gh required. Every GitHub call — the agent's pushes, PR
# creation, and this script's own PR polling — runs inside the container,
# authenticated by a keychain token passed as GH_TOKEN.
docker info >/dev/null 2>&1 \
  || die "Docker is not running. Start it with 'colima start' or open Docker Desktop."
docker image inspect "$IMAGE" >/dev/null 2>&1 \
  || die "image '$IMAGE' not found. Build it:  docker build -t $IMAGE -f Dockerfile.agent ."

GH_RUN_TOKEN=""
GH_AGENT_TOKEN=""
OPENROUTER_KEY=""
ANTHROPIC_KEY=""

if [[ "$MODE" == "ghsetup" ]]; then
  # One-time repo administration needs an admin-capable token, deliberately
  # separate from the agent's minimal token.
  GH_RUN_TOKEN="$(keychain gh-admin)"
else
  GH_AGENT_TOKEN="$(keychain gh-agent)"
  if [[ "$ENGINE" == "claude" ]]; then
    ANTHROPIC_KEY="$(keychain anthropic)"
    OPENROUTER_KEY="$(security find-generic-password -s openrouter -w 2>/dev/null || true)"
  else
    OPENROUTER_KEY="$(keychain openrouter)"
  fi
fi

mkdir -p logs
[[ "$MODE" == "plan" && ! -f "$PLAN" ]] && \
  die "$PLAN not found. Bootstrap it first:  ./run.sh --init \"<project description>\""

# ── Docker wrappers ──────────────────────────────────────────────────────────
in_container() {
  docker run --rm \
    -v "$REPO_DIR:/work" \
    -v agent-cache:/home/agent/.cache \
    -v agent-claude-home:/home/agent/.claude \
    -e OPENROUTER_API_KEY="$OPENROUTER_KEY" \
    -e ANTHROPIC_API_KEY="$ANTHROPIC_KEY" \
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

run_agent() {
  local prompt="$1" log
  log="logs/$(date +%Y%m%d-%H%M%S)-$ENGINE.jsonl"
  info "engine: $ENGINE"
  info "log: $log"
  echo

  if [[ "$ENGINE" == "claude" ]]; then
    # Headless Claude Code. bypassPermissions is safe for the same reason it
    # is for OpenCode: the container is the boundary. Deny rules in
    # .claude/settings.json still apply even in this mode.
    in_container claude -p "$prompt" \
      --permission-mode bypassPermissions \
      --output-format stream-json --verbose \
      ${MODEL:+--model "$MODEL"} | tee "$log"
  else
    in_container opencode run --format json ${MODEL:+-m "$MODEL"} "$prompt" | tee "$log"
  fi
  local rc=${PIPESTATUS[0]}

  echo
  if command -v jq >/dev/null 2>&1 && [[ -s "$log" ]]; then
    echo "  tools used:"
    # Two shapes: OpenCode emits flat {"type":"tool_use",...} events; Claude
    # Code nests tool_use blocks inside assistant messages.
    {
      jq -r 'select(.type=="tool_use") | .tool // .name // empty' "$log" 2>/dev/null
      jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="tool_use") | .name // empty' "$log" 2>/dev/null
    } | sed 's/^/    /' | sort | uniq -c | sort -rn || true
    # Claude Code's final result event carries the session cost — surface it.
    jq -r 'select(.type=="result") | .total_cost_usd? // empty
           | "  session cost: $" + (.|tostring)' "$log" 2>/dev/null | tail -1 || true
  fi
  return "$rc"
}

made_commits() { git log --oneline origin/main..HEAD 2>/dev/null | grep -q .; }
current_pr()   { gh_c pr view --json number -q .number 2>/dev/null; }

# Poll until the PR merges, CI fails, or we time out. No agent turns, no
# tokens burned — one containerized gh call per poll, state and CI verdict in
# a single query.
wait_for_merge() {
  local pr="$1" deadline=$(( $(date +%s) + TIMEOUT_MIN * 60 ))
  echo "> waiting for PR #$pr to merge (timeout ${TIMEOUT_MIN}m)"
  while (( $(date +%s) < deadline )); do
    local out state fails
    out="$(gh_c pr view "$pr" --json state,statusCheckRollup \
      -q '[.state, ([.statusCheckRollup[]? | select(.conclusion=="FAILURE" or .conclusion=="TIMED_OUT" or .conclusion=="CANCELLED")] | length | tostring)] | join(" ")' \
      2>/dev/null || true)"
    state="${out%% *}"
    fails="${out##* }"
    [[ -z "$state" ]] && state="UNKNOWN"
    [[ "$fails" == "$state" || -z "$fails" ]] && fails=0
    case "$state" in
      MERGED) info "merged"; return 0 ;;
      CLOSED) info "PR was closed without merging"; return 2 ;;
    esac
    if [[ "$fails" -gt 0 ]] 2>/dev/null; then info "CI failed on PR #$pr"; return 3; fi
    sleep 20
  done
  info "timed out waiting for PR #$pr"
  return 1
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

# ── Prompt fragments ─────────────────────────────────────────────────────────
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

0. First run: git switch -c chore/plan-draft
   (direct pushes to main are blocked, so everything below happens on this
   branch)

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
   - Aim for 8 to 20 items. Do not plan the whole product; plan the first
     working version. You will be able to add more as you build.

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
cat <<'EOF'
Audit the repository against PLAN.md and correct the plan. Do not implement
features in this session.

0. First run: git switch -c chore/replan
   (direct pushes to main are blocked, so everything below happens on this
   branch)

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
   "- [ ]" lines, so anything else is invisible to it.
7. Commit with a message starting "chore: ", push, and open a PR with:
     gh pr create --fill --label plan
8. Stop.

This is the one session where you are allowed to restructure PLAN.md freely.
EOF
}

prompt_item() {
cat <<EOF
Your task for this session is exactly this item from PLAN.md:

    $1

Do this:

1. Implement only that item. Do not start any other item and do not refactor
   unrelated code.
2. Write or extend tests that prove it works.
3. Run the project's lint and test commands. Fix failures until green.
4. In PLAN.md, change that item's "- [ ]" to "- [x]".
5. $(discovery_clause)
6. Follow the workflow in AGENTS.md: branch, commit, push, and open a pull
   request with the "automated" label.
7. Stop. Do not wait for CI, do not merge, do not start the next item.
EOF
}

# ── One-shot modes ───────────────────────────────────────────────────────────
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
    run_agent "$(prompt_init)"; rc=$?
    echo
    if made_commits; then
      pr="$(current_pr || true)"
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
    rule; echo "MODE: replan — auditing PLAN.md against the code"; rule
    graph_sync
    run_agent "$(prompt_replan)"; exit $? ;;
  task)
    [[ -n "$ARG_TEXT" ]] || die "--task needs text"
    rule; echo "MODE: task — one-off"; rule
    # If we're already on a feature branch, tell the agent to stay on it.
    # Otherwise AGENTS.md's "always create a branch" rule would make a weak
    # model open a SECOND branch/PR instead of updating the existing one —
    # exactly wrong for the "fix CI on this PR" flow.
    cur_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
    if [[ "$cur_branch" != "main" && "$cur_branch" != "master" ]]; then
      ARG_TEXT="$ARG_TEXT

NOTE: you are already on branch '$cur_branch', which has an open pull request.
Stay on THIS branch — do not create a new one. Commit and push here so the
existing PR updates. The 'create a branch' step in AGENTS.md does not apply."
      info "on branch '$cur_branch' — agent will update the existing PR"
    fi
    graph_sync
    run_agent "$ARG_TEXT"; rc=$?
    made_commits && git log --oneline origin/main..HEAD | sed 's/^/  /' \
                 || echo "  no commits — the agent wrote nothing"
    exit "$rc" ;;
esac

# ── Plan loop ────────────────────────────────────────────────────────────────
SNAP="$(mktemp -t planbefore)"
trap 'rm -f "$SNAP"' EXIT

completed_n=0
total_added=0

for (( i = 1; i <= COUNT; i++ )); do
  git switch main --quiet 2>/dev/null || true
  git_pull_c

  before_remaining="$(plan_remaining)"
  before_done="$(plan_done_count)"
  cp "$PLAN" "$SNAP" 2>/dev/null || true

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
      echo "Have the agent propose the next wave:  ./run.sh --replan"
      echo "(it audits the code, adds what's clearly missing, opens a plan PR"
      echo "for your review) — or add items yourself."
    fi
    break
  fi

  item="$(plan_next)"
  echo
  rule
  printf 'TASK %d/%s   ·   %s remaining\n' "$i" \
    "$([[ "$COUNT" -ge 9999 ]] && echo all || echo "$COUNT")" "$before_remaining"
  echo "$item"
  rule

  graph_sync
  run_agent "$(prompt_item "$item")"

  if ! made_commits; then
    echo
    echo "STOPPING: no commits were made. The model may be failing at tool"
    echo "calls — look at the tool list above. If there are no 'bash' calls,"
    echo "change the model in opencode.json."
    exit 1
  fi

  pr="$(current_pr || true)"
  if [[ -z "$pr" ]]; then
    echo
    echo "STOPPING: commits exist but no pull request was opened."
    echo "Open it manually, or re-run to let the agent retry."
    exit 1
  fi
  info "PR #$pr opened"

  if (( ! WAIT )); then
    info "--no-wait: continuing without waiting for the merge"
    info "note: PLAN.md on main is stale, so the next item may repeat"
    continue
  fi

  wait_for_merge "$pr"
  case $? in
    0) : ;;
    3) fb="$(gh_c pr view "$pr" --json headRefName -q .headRefName 2>/dev/null || echo '<branch>')"
       echo
       echo "STOPPING: CI failed on PR #$pr."
       echo "Fix it with a follow-up on the same branch:"
       echo "  git switch $fb"
       echo "  ./run.sh --task \"<what to fix>\""
       exit 1 ;;
    *) pu="$(gh_c pr view "$pr" --json url -q .url 2>/dev/null || true)"
       echo
       echo "STOPPING: PR #$pr did not merge. Take a look: ${pu:-open it on GitHub}"
       exit 1 ;;
  esac

  # ── Accounting: did it tick its box, and did the plan grow? ───────────────
  head_branch="$(gh_c pr view "$pr" --json headRefName -q .headRefName 2>/dev/null || true)"
  git switch main --quiet 2>/dev/null || true
  git_pull_c
  # Remote branch is deleted by delete-branch-on-merge; tidy the local copy too.
  [[ -n "$head_branch" ]] && git branch -D "$head_branch" >/dev/null 2>&1 || true

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
echo "plan:          $(plan_done_count) done, $(plan_remaining) remaining"
n="$(plan_next || true)"
[[ -n "${n:-}" ]] && echo "next:          $n"
