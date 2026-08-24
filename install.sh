#!/usr/bin/env bash
#
# agentloop installer — copies the autonomous development loop into a project.
#
#   Local clone:   /path/to/agentloop/install.sh [target-dir] [options]
#   One-liner:     curl -fsSL https://raw.githubusercontent.com/yildirimarda/agentloop/main/install.sh | bash -s -- [options]
#
# Options
#   --ref REF            install a specific tag or branch (default: newest
#                        version tag on the repo, falling back to the default
#                        branch). Only relevant in remote mode.
#   --repo URL           agentloop repo URL (default baked below; also
#                        AGENTLOOP_REPO env var)
#   --update             refresh an existing install (requires the .agentloop
#                        stamp; managed files are replaced, yours are not)
#   --force              skip the already-installed and not-a-git-repo guards
#   --model ID           set opencode.json "model" (openrouter/ prefix added
#                        if missing)
#   --small-model ID     set opencode.json "small_model"
#   --dry-run            print what would happen, change nothing
#   -h, --help           this
#
# File classes — nothing of yours is ever silently overwritten:
#   managed  run.sh, setup-github.sh, workflows/automerge.yml,
#            workflows/release.yml
#            → replaced on --update. If a FOREIGN file with the same name
#              exists on fresh install, yours is kept and ours lands as
#              <file>.agentloop-new with a warning.
#   merged   CLAUDE.md, .mcp.json, .claude/settings.json
#            → combined with what you have: CLAUDE.md gains an @AGENTS.md
#              import line, .mcp.json gains the graphify server alongside
#              your servers, settings.json gains our deny rules alongside
#              your rules. Idempotent; your entries always survive.
#   yours    PLAN.md, AGENTS.md, opencode.json, Dockerfile.agent,
#            workflows/ci.yml
#            → installed once, then never touched. On --update, if the
#              TEMPLATE version actually changed since your install, the new
#              template lands as <file>.agentloop-new for you to diff.
#              PLAN.md never even gets a .agentloop-new — your plan is
#              authoritative by design.
#
set -euo pipefail

DEFAULT_REPO="https://github.com/yildirimarda/agentloop.git"
REPO="${AGENTLOOP_REPO:-$DEFAULT_REPO}"
REF=""
TARGET=""
FORCE=0
UPDATE=0
DRY=0
MODEL=""
SMALL_MODEL=""
CONFLICTS=0

MANAGED_FILES=(
  run.sh
  setup-github.sh
  .github/workflows/automerge.yml
  .github/workflows/release.yml
)
USER_FILES=(
  PLAN.md
  AGENTS.md
  opencode.json
  Dockerfile.agent
  .github/workflows/ci.yml
)
GITIGNORE_LINES=(
  "logs/"
  "graphify-out/"
  ".opencode/"
  "*.agentloop-new"
)

die()  { echo "error: $*" >&2; exit 1; }
note() { echo "  $*"; }
warn() { echo "  ⚠ $*"; }

# Print the header comment block (everything from line 2 up to the first
# non-comment line) — no fixed line range to fall out of sync with.
usage() {
  awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0" 2>/dev/null \
    || echo "agentloop installer — see the repository README."
}

filehash() {
  if command -v md5sum >/dev/null 2>&1; then md5sum < "$1" | cut -d' ' -f1
  else md5 -q "$1"; fi
}

while (( $# )); do
  case "$1" in
    --ref)          REF="${2:?--ref needs a value}"; shift 2 ;;
    --repo)         REPO="${2:?--repo needs a URL}"; shift 2 ;;
    --update)       UPDATE=1; shift ;;
    --force)        FORCE=1; shift ;;
    --dry-run)      DRY=1; shift ;;
    --model)        MODEL="${2:?--model needs an id}"; shift 2 ;;
    --small-model)  SMALL_MODEL="${2:?--small-model needs an id}"; shift 2 ;;
    -h|--help)      usage; exit 0 ;;
    -*)             die "unknown option: $1 (try --help)" ;;
    *)              TARGET="$1"; shift ;;
  esac
done

TARGET="${TARGET:-$PWD}"
[[ -d "$TARGET" ]] || die "target directory not found: $TARGET"
TARGET="$(cd "$TARGET" && pwd)"
STAMP="$TARGET/.agentloop"

# ── Locate the template: local clone or remote fetch ─────────────────────────
SRC=""
TMP=""
REF_USED="local"
# Note: must end with status 0 — an EXIT trap's failing last command would
# override the script's own exit code under `set -e`.
cleanup() { if [[ -n "$TMP" ]]; then rm -rf "$TMP"; fi; }
trap cleanup EXIT

SCRIPT_PATH="${BASH_SOURCE[0]:-}"
if [[ -n "$SCRIPT_PATH" && -f "$SCRIPT_PATH" ]]; then
  d="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
  [[ -d "$d/template" ]] && SRC="$d"
fi

if [[ -z "$SRC" ]]; then
  # The placeholder literal is split ("CHANGE""_ME") on purpose: personalising
  # the repo URL with a global `sed s/CHANGE_ME/you/g` must fix DEFAULT_REPO
  # without being able to rewrite this guard into nonsense.
  [[ "$REPO" == *"CHANGE""_ME"* ]] && die "remote mode needs a repo URL.
Edit DEFAULT_REPO in install.sh, or pass --repo, or set AGENTLOOP_REPO."
  command -v git >/dev/null || die "git is required for remote mode"
  if [[ -z "$REF" ]]; then
    REF="$(git ls-remote --tags --refs "$REPO" 2>/dev/null \
           | awk -F/ '{print $NF}' | grep -E '^v?[0-9]' | sort -V | tail -1 || true)"
  fi
  TMP="$(mktemp -d)"
  echo "> fetching agentloop ${REF:-(default branch)} from $REPO"
  if [[ -n "$REF" ]]; then
    git clone --quiet --depth 1 --branch "$REF" "$REPO" "$TMP/src" \
      || die "could not clone ref '$REF' from $REPO"
    REF_USED="$REF"
  else
    git clone --quiet --depth 1 "$REPO" "$TMP/src" || die "could not clone $REPO"
    REF_USED="default-branch"
  fi
  SRC="$TMP/src"
fi

[[ -d "$SRC/template" ]] || die "template/ not found in source ($SRC)"
VERSION="$(cat "$SRC/version.txt" 2>/dev/null || echo unknown)"

# ── Guards ────────────────────────────────────────────────────────────────────
STAMPED=0
[[ -f "$STAMP" ]] && STAMPED=1

if (( STAMPED )) && (( ! UPDATE )) && (( ! FORCE )); then
  die "agentloop is already installed here (see .agentloop).
Re-run with --update to refresh it."
fi
if ! git -C "$TARGET" rev-parse --git-dir >/dev/null 2>&1; then
  (( FORCE )) || die "$TARGET is not a git repository.
The loop needs git + GitHub to work. Use --force to install anyway."
fi

echo "> installing agentloop $VERSION ($REF_USED) into $TARGET"
echo

stored_hash() {
  # hash recorded at last install for a template user-file
  { grep "^hash:$1=" "$STAMP" 2>/dev/null || true; } | cut -d= -f2
}

# ── Managed files: ours to replace, but never a stranger's ──────────────────
copy_managed() {
  local rel="$1" src="$SRC/template/$1" dest="$TARGET/$1"
  if [[ ! -e "$dest" ]]; then
    (( DRY )) && { note "[dry] install   $rel"; return; }
    mkdir -p "$(dirname "$dest")"; cp "$src" "$dest"; note "installed  $rel"
  elif cmp -s "$src" "$dest"; then
    note "unchanged  $rel"
  elif (( STAMPED )); then
    # the stamp says this file is ours from a previous install → refresh it
    (( DRY )) && { note "[dry] update    $rel"; return; }
    cp "$src" "$dest"; note "updated    $rel"
  else
    # fresh install onto a foreign file with the same name → never clobber
    (( DRY )) && { note "[dry] conflict  $rel (would keep yours, write $rel.agentloop-new)"; return; }
    cp "$src" "$dest.agentloop-new"
    warn "conflict: $rel already exists and is not agentloop's — kept yours, ours saved as $rel.agentloop-new"
    CONFLICTS=$((CONFLICTS + 1))
  fi
}

# ── User files: installed once, never touched again ─────────────────────────
copy_user() {
  local rel="$1" src="$SRC/template/$1" dest="$TARGET/$1"
  if [[ ! -e "$dest" ]]; then
    (( DRY )) && { note "[dry] install   $rel"; return; }
    mkdir -p "$(dirname "$dest")"; cp "$src" "$dest"; note "installed  $rel"
    return
  fi
  if cmp -s "$src" "$dest"; then note "unchanged  $rel"; return; fi

  if [[ "$rel" == "PLAN.md" ]]; then
    note "kept yours PLAN.md (your plan is authoritative — never templated over)"
    return
  fi

  # Only offer a .agentloop-new when the TEMPLATE itself changed since the
  # last install — otherwise every update would spam .new files just because
  # the user customised theirs (which is expected).
  local new_hash old_hash
  new_hash="$(filehash "$src")"
  old_hash="$(stored_hash "$rel")"
  if (( STAMPED )) && [[ "$new_hash" == "$old_hash" ]]; then
    note "kept yours $rel"
  else
    (( DRY )) && { note "[dry] keep yours $rel, write $rel.agentloop-new"; return; }
    cp "$src" "$dest.agentloop-new"
    if (( STAMPED )); then
      note "kept yours $rel  (template changed — new version saved as $rel.agentloop-new)"
    else
      warn "conflict: $rel already exists — kept yours, template saved as $rel.agentloop-new"
      CONFLICTS=$((CONFLICTS + 1))
    fi
  fi
}

# ── Merged files: yours + ours, additively, idempotently ────────────────────
merge_claude_md() {
  local src="$SRC/template/CLAUDE.md" dest="$TARGET/CLAUDE.md"
  if [[ ! -e "$dest" ]]; then
    (( DRY )) && { note "[dry] install   CLAUDE.md"; return; }
    cp "$src" "$dest"; note "installed  CLAUDE.md"
  elif grep -q '^@AGENTS.md' "$dest"; then
    note "unchanged  CLAUDE.md (already imports AGENTS.md)"
  else
    (( DRY )) && { note "[dry] merge     CLAUDE.md (append @AGENTS.md import)"; return; }
    cat >> "$dest" <<'EOF'

@AGENTS.md
<!-- agentloop: the import above pulls in the autonomous-loop workflow
     contract. Keep it; everything else in this file is yours. -->
EOF
    note "merged     CLAUDE.md (appended @AGENTS.md import below your content)"
  fi
}

merge_json() {
  # $1 = rel path, $2 = python merge program (reads DEST SRC argv)
  local rel="$1" prog="$2" src="$SRC/template/$1" dest="$TARGET/$1"
  if [[ ! -e "$dest" ]]; then
    (( DRY )) && { note "[dry] install   $rel"; return; }
    mkdir -p "$(dirname "$dest")"; cp "$src" "$dest"; note "installed  $rel"
    return
  fi
  if cmp -s "$src" "$dest"; then note "unchanged  $rel"; return; fi
  if ! command -v python3 >/dev/null 2>&1; then
    (( DRY )) && { note "[dry] would need python3 to merge $rel"; return; }
    cp "$src" "$dest.agentloop-new"
    warn "python3 not found — could not merge $rel; ours saved as $rel.agentloop-new"
    CONFLICTS=$((CONFLICTS + 1))
    return
  fi
  (( DRY )) && { note "[dry] merge     $rel"; return; }
  local out
  out="$(python3 -c "$prog" "$dest" "$src")"
  note "$out $rel"
}

MERGE_MCP='
import json, sys
dest, src = sys.argv[1], sys.argv[2]
d = json.load(open(dest))
s = json.load(open(src))
d.setdefault("mcpServers", {})
added = False
for k, v in s.get("mcpServers", {}).items():
    if k not in d["mcpServers"]:
        d["mcpServers"][k] = v
        added = True
if added:
    open(dest, "w").write(json.dumps(d, indent=2) + "\n")
print("merged    " if added else "unchanged ")
'

MERGE_SETTINGS='
import json, sys
dest, src = sys.argv[1], sys.argv[2]
d = json.load(open(dest))
s = json.load(open(src))
perm = d.setdefault("permissions", {})
deny = perm.setdefault("deny", [])
added = False
for rule in s.get("permissions", {}).get("deny", []):
    if rule not in deny:
        deny.append(rule)
        added = True
if added:
    open(dest, "w").write(json.dumps(d, indent=2) + "\n")
print("merged    " if added else "unchanged ")
'

for f in "${MANAGED_FILES[@]}"; do copy_managed "$f"; done
for f in "${USER_FILES[@]}";    do copy_user "$f";    done
merge_claude_md
merge_json ".mcp.json" "$MERGE_MCP"
merge_json ".claude/settings.json" "$MERGE_SETTINGS"

# ── Housekeeping ──────────────────────────────────────────────────────────────
if (( ! DRY )); then
  chmod +x "$TARGET/run.sh" "$TARGET/setup-github.sh" 2>/dev/null || true

  touch "$TARGET/.gitignore"
  for line in "${GITIGNORE_LINES[@]}"; do
    grep -qxF "$line" "$TARGET/.gitignore" || echo "$line" >> "$TARGET/.gitignore"
  done

  {
    echo "version=$VERSION"
    echo "ref=$REF_USED"
    echo "repo=$REPO"
    echo "installed=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for f in "${USER_FILES[@]}"; do
      echo "hash:$f=$(filehash "$SRC/template/$f")"
    done
  } > "$STAMP"

  if [[ -n "$MODEL" || -n "$SMALL_MODEL" ]]; then
    command -v python3 >/dev/null || die "--model needs python3 on PATH"
    python3 - "$TARGET/opencode.json" "$MODEL" "$SMALL_MODEL" <<'PY'
import json, sys
path, model, small = sys.argv[1], sys.argv[2], sys.argv[3]
def norm(m): return m if m.startswith("openrouter/") else "openrouter/" + m
d = json.load(open(path))
if model: d["model"] = norm(model)
if small: d["small_model"] = norm(small)
open(path, "w").write(json.dumps(d, indent=2) + "\n")
PY
    [[ -n "$MODEL" ]]       && note "set model       $MODEL"
    [[ -n "$SMALL_MODEL" ]] && note "set small_model $SMALL_MODEL"
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
if (( CONFLICTS )); then
  echo
  warn "$CONFLICTS conflict(s). Your files were kept; review each *.agentloop-new:"
  warn "  diff <file> <file>.agentloop-new   → merge what you want, delete the .new"
  warn "If AGENTS.md was among them, merge the workflow contract in — the loop"
  warn "depends on it."
fi

echo
echo "Done. Remaining setup (skip what you've already done on this machine):"
if grep -q CHANGE_ME "$TARGET/opencode.json" 2>/dev/null; then
  echo "  1. Pick models: edit opencode.json, or re-run with"
  echo "       --model <vendor/model> --small-model <vendor/model>"
else
  echo "  1. Models configured ✓"
fi
echo "  2. Fill the 'Project reference' section at the bottom of AGENTS.md"
echo "  3. Adapt .github/workflows/ci.yml to this project's stack"
echo "  4. Build the container once per machine (shared by all projects):"
echo "       docker build -t agent -f Dockerfile.agent ."
echo "  5. Keychain (once per machine):"
echo "       security add-generic-password -s openrouter -a \"\$USER\" -w 'sk-or-...'"
echo "       security add-generic-password -s gh-agent   -a \"\$USER\" -w 'github_pat_...'"
echo "       security add-generic-password -s anthropic  -a \"\$USER\" -w 'sk-ant-...'   # only for --engine claude"
echo "  6. ./setup-github.sh   (branch protection, auto-merge, labels)"
echo "  7. ./run.sh --init \"<project description>\"   or write PLAN.md by hand"
echo
echo "Guide: see docs/SETUP.md in the agentloop repository."
