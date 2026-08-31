#!/usr/bin/env bash
# Installer test suite. Run from anywhere: bash tests/install-test.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# The suite creates throwaway repos and commits in them. CI runners have no
# git identity configured, so carry one via environment — repo- and
# machine-config independent, and it never touches the runner's global config.
export GIT_AUTHOR_NAME="agentloop-test"  GIT_AUTHOR_EMAIL="test@agentloop.local"
export GIT_COMMITTER_NAME="agentloop-test" GIT_COMMITTER_EMAIL="test@agentloop.local"

cd "$TMP"
git init -q proj
cd proj
git commit --allow-empty -q -m init

# ── 1. Fresh install ─────────────────────────────────────────────────────────
"$ROOT/install.sh" . >/dev/null

EXPECTED=(
  run.sh setup-github.sh CLAUDE.md .mcp.json .claude/settings.json
  .github/workflows/automerge.yml .github/workflows/release.yml
  PLAN.md AGENTS.md opencode.json Dockerfile.agent .github/workflows/ci.yml
  .agentloop .gitignore
)
for f in "${EXPECTED[@]}"; do
  [[ -e "$f" ]] || fail "missing after install: $f"
done
[[ -x run.sh && -x setup-github.sh ]] || fail "scripts not executable"

bash -n run.sh && bash -n setup-github.sh || fail "installed scripts have syntax errors"
python3 -c "import json;[json.load(open(f)) for f in ['opencode.json','.mcp.json','.claude/settings.json']]" \
  || fail "installed JSON invalid"

grep -qxF "logs/" .gitignore           || fail ".gitignore missing logs/"
grep -qxF "*.agentloop-new" .gitignore || fail ".gitignore missing *.agentloop-new"
grep -q "^version=" .agentloop         || fail ".agentloop stamp malformed"

# run.sh --next works pre-docker (exits before any docker/keychain check)
./run.sh --next >/dev/null || fail "run.sh --next failed on fresh install"

# ── 2. Re-install without --update must refuse ───────────────────────────────
if "$ROOT/install.sh" . >/dev/null 2>&1; then
  fail "second install should refuse without --update"
fi

# ── 3. --update refreshes and preserves ──────────────────────────────────────
"$ROOT/install.sh" . --update >/dev/null || fail "--update failed"

# User customisation + UNCHANGED template → kept, and NO .agentloop-new spam
echo "# local customisation" >> AGENTS.md
"$ROOT/install.sh" . --update >/dev/null
grep -q "local customisation" AGENTS.md || fail "--update clobbered a user file"
[[ -f AGENTS.md.agentloop-new ]] && fail "unwanted .agentloop-new when template did not change"

# User customisation + CHANGED template → kept, and .agentloop-new offered
cp -R "$ROOT" "$TMP/src2"
echo "# template evolved" >> "$TMP/src2/template/AGENTS.md"
"$TMP/src2/install.sh" . --update >/dev/null
grep -q "local customisation" AGENTS.md || fail "changed-template update clobbered a user file"
[[ -f AGENTS.md.agentloop-new ]] || fail "expected AGENTS.md.agentloop-new after template change"
grep -q "template evolved" AGENTS.md.agentloop-new || fail ".agentloop-new is not the new template"
rm -f AGENTS.md.agentloop-new

# Managed file: local edits are overwritten by --update (stamp marks it ours)
echo "# tamper" >> run.sh
"$ROOT/install.sh" . --update >/dev/null
grep -q "tamper" run.sh && fail "--update did not refresh a managed file"

# ── 4. Model flags ────────────────────────────────────────────────────────────
"$ROOT/install.sh" . --update --model foo/bar --small-model openrouter/foo/baz >/dev/null
python3 - <<'PY' || fail "model flags not applied"
import json
d = json.load(open("opencode.json"))
assert d["model"] == "openrouter/foo/bar", d["model"]
assert d["small_model"] == "openrouter/foo/baz", d["small_model"]
PY

# ── 5. --dry-run changes nothing ──────────────────────────────────────────────
before="$(find . -type f | sort | md5sum 2>/dev/null || find . -type f | sort | md5)"
"$ROOT/install.sh" . --update --dry-run >/dev/null
after="$(find . -type f | sort | md5sum 2>/dev/null || find . -type f | sort | md5)"
[[ "$before" == "$after" ]] || fail "--dry-run created or removed files"

# ── 6. Non-git target refused without --force ─────────────────────────────────
mkdir "$TMP/notgit"
if "$ROOT/install.sh" "$TMP/notgit" >/dev/null 2>&1; then
  fail "install into non-git dir should refuse without --force"
fi
"$ROOT/install.sh" "$TMP/notgit" --force >/dev/null || fail "--force into non-git dir failed"

# ── 7. Fresh install into a project that ALREADY has these files ─────────────
cd "$TMP"
git init -q proj2 && cd proj2 && git commit --allow-empty -q -m init

echo "# my project rules" > CLAUDE.md
printf '%s\n' '{"mcpServers":{"mydb":{"command":"db-mcp","args":[]}}}' > .mcp.json
mkdir -p .claude
printf '%s\n' '{"permissions":{"allow":["Bash(ls)"],"deny":["Bash(rm -rf /)"]},"other":"keep-me"}' > .claude/settings.json
printf '%s\n' '# Plan' '- [ ] my existing item' > PLAN.md
printf '%s\n' '#!/bin/bash' 'echo my own runner' > run.sh
mkdir -p .github/workflows
printf '%s\n' 'name: my-pipeline' 'on: [push]' 'jobs:' '  build-and-test:' '    runs-on: ubuntu-latest' '    steps:' '      - run: echo hi' > .github/workflows/ci.yml

"$ROOT/install.sh" . >/dev/null 2>&1 || fail "install into pre-populated project failed"

# CLAUDE.md: merged, both contents present, exactly one import line
grep -q "my project rules" CLAUDE.md         || fail "CLAUDE.md lost user content"
grep -q '^@AGENTS.md' CLAUDE.md              || fail "CLAUDE.md missing @AGENTS.md import"
# .mcp.json: both servers
python3 - <<'PY' || fail ".mcp.json merge wrong"
import json
d = json.load(open(".mcp.json"))
assert "mydb" in d["mcpServers"], "user server lost"
assert "graphify" in d["mcpServers"], "graphify not added"
PY
# settings.json: user rules + ours, unrelated keys preserved
python3 - <<'PY' || fail ".claude/settings.json merge wrong"
import json
d = json.load(open(".claude/settings.json"))
assert "Bash(ls)" in d["permissions"]["allow"], "user allow lost"
assert "Bash(rm -rf /)" in d["permissions"]["deny"], "user deny lost"
assert "Bash(terraform apply)" in d["permissions"]["deny"], "template deny not merged"
assert d.get("other") == "keep-me", "unrelated key lost"
PY
# PLAN.md: authoritative, untouched, no .new
grep -q "my existing item" PLAN.md           || fail "PLAN.md was modified"
[[ -f PLAN.md.agentloop-new ]] && fail "PLAN.md should never get a .agentloop-new"
# foreign run.sh: kept, ours as .new
grep -q "my own runner" run.sh               || fail "foreign run.sh was clobbered"
[[ -f run.sh.agentloop-new ]]                || fail "expected run.sh.agentloop-new for foreign file"
# existing CI: authoritative — kept untouched, and NO .agentloop-new noise
grep -q "build-and-test" .github/workflows/ci.yml || fail "existing ci.yml was clobbered"
[[ -f .github/workflows/ci.yml.agentloop-new ]] && fail "existing CI should not get a .agentloop-new"

# ── 8. Merges are idempotent ──────────────────────────────────────────────────
"$ROOT/install.sh" . --update >/dev/null 2>&1
n="$(grep -c '^@AGENTS.md' CLAUDE.md)"
[[ "$n" == "1" ]] || fail "CLAUDE.md import duplicated on re-run (count=$n)"
python3 - <<'PY' || fail "mcp merge not idempotent"
import json
d = json.load(open(".mcp.json"))
assert set(d["mcpServers"]) == {"mydb", "graphify"}, sorted(d["mcpServers"])
PY

# ── 9. --dry-run announces the right actions on a fresh target ────────────────
cd "$TMP"
git init -q proj3 && cd proj3 && git commit --allow-empty -q -m init
dryout="$("$ROOT/install.sh" . --dry-run)"
echo "$dryout" | grep -q '\[dry\] install   run.sh'   || fail "dry-run: missing install action for run.sh"
echo "$dryout" | grep -q '\[dry\] install   PLAN.md'  || fail "dry-run: missing install action for PLAN.md"
[[ -e run.sh || -e PLAN.md || -e .agentloop ]] && fail "dry-run created files on a fresh target"

# ── 10. --check reports installed version; --uninstall removes only ours ─────
cd "$TMP/proj"
# capture-then-grep: grep -q on a live pipe would SIGPIPE the installer's
# later output lines and trip pipefail
chk_out="$("$ROOT/install.sh" . --check)"
echo "$chk_out" | grep -q '^installed: ' || fail "--check did not report installed version"
"$ROOT/install.sh" . --uninstall >/dev/null
[[ -e run.sh ]] && fail "--uninstall left run.sh behind"
[[ -e setup-github.sh ]] && fail "--uninstall left setup-github.sh behind"
[[ -e .agentloop ]] && fail "--uninstall left the stamp behind"
[[ -e AGENTS.md.agentloop-new ]] && fail "--uninstall left .agentloop-new files behind"
grep -q "local customisation" AGENTS.md || fail "--uninstall touched a user file (AGENTS.md)"
[[ -e PLAN.md && -e opencode.json && -e Dockerfile.agent ]] || fail "--uninstall removed user files"
[[ -e CLAUDE.md && -e .mcp.json && -e .claude/settings.json ]] || fail "--uninstall removed merged files"
"$ROOT/install.sh" . >/dev/null 2>&1 || fail "reinstall after --uninstall failed"
[[ -x run.sh && -f .agentloop ]] || fail "reinstall incomplete"

# ── 11. Live-stream parsers handle both engines' recorded event shapes ───────
# Extract stream_view from the installed run.sh and feed it fixture lines
# captured from real sessions. Guards the parsers against schema regressions.
eval "$(sed -n '/^stream_view()/,/^}$/p' run.sh)"
sv_out="$(printf '%s\n' \
  '{"type":"tool_use","part":{"type":"tool","tool":"bash","state":{"status":"completed","input":{"command":"git status"}},"metadata":{"openrouter":{"reasoning_details":[{"type":"reasoning.text","text":"Check the branch first."}]}}}}' \
  '{"type":"step_finish","part":{"type":"step-finish","tokens":{"total":10309}}}' \
  '{"type":"text","part":{"type":"text","text":"All done."}}' \
  '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash"},{"type":"text","text":"claude says hi"}]}}' \
  '{"type":"error","error":{"message":"rate limited"}}' \
  'not json at all' \
  | stream_view)"
echo "$sv_out" | grep -q '⋯ Check the branch first.' || fail "stream_view: reasoning not shown"
echo "$sv_out" | grep -q '→ bash: git status'        || fail "stream_view: tool+input not shown"
echo "$sv_out" | grep -q 'step done (10k tok)'       || fail "stream_view: step tokens not shown"
echo "$sv_out" | grep -q 'All done.'                 || fail "stream_view: opencode text not shown"
echo "$sv_out" | grep -q '→ Bash'                    || fail "stream_view: claude tool_use not shown"
echo "$sv_out" | grep -q '✖ rate limited'            || fail "stream_view: error not shown"

# Codex fixtures (shapes verbatim from the official --json docs)
cx_out="$(printf '%s\n' \
  '{"type":"thread.started","thread_id":"0199a213-81c0-7800-8aa1-bbab2a035a53"}' \
  '{"type":"item.started","item":{"id":"item_1","type":"command_execution","command":"bash -lc ls","status":"in_progress"}}' \
  '{"type":"item.completed","item":{"id":"item_2","type":"reasoning","text":"List the repo first."}}' \
  '{"type":"item.completed","item":{"id":"item_3","type":"agent_message","text":"Repo contains docs and examples."}}' \
  '{"type":"turn.completed","usage":{"input_tokens":24763,"cached_input_tokens":24448,"output_tokens":122}}' \
  '{"type":"turn.failed","error":{"message":"model overloaded"}}' \
  | stream_view)"
echo "$cx_out" | grep -q '→ exec: bash -lc ls'              || fail "stream_view: codex command not shown"
echo "$cx_out" | grep -q '⋯ List the repo first.'           || fail "stream_view: codex reasoning not shown"
echo "$cx_out" | grep -q 'Repo contains docs and examples.' || fail "stream_view: codex agent_message not shown"
echo "$cx_out" | grep -q 'turn done (24k tok)'              || fail "stream_view: codex turn tokens not shown"
echo "$cx_out" | grep -q '✖ turn failed: model overloaded'  || fail "stream_view: codex turn.failed not shown"

# ── 12. --only installs the requested subset and nothing else ─────────────────
mkdir -p "$TMP/only" && cd "$TMP/only"
git init -q . && git commit -q --allow-empty -m init
"$ROOT/install.sh" . --only workflows,claude >/dev/null
[[ -e .github/workflows/automerge.yml ]] || fail "--only workflows: automerge.yml missing"
[[ -e .github/workflows/ci.yml ]]        || fail "--only workflows: ci.yml missing"
[[ -e .github/workflows/release.yml ]]   || fail "--only workflows: release.yml missing"
[[ -e CLAUDE.md && -e .mcp.json && -e .claude/settings.json ]] || fail "--only claude: merge files missing"
[[ -e run.sh ]]        && fail "--only: run.sh installed outside subset"
[[ -e PLAN.md ]]       && fail "--only: PLAN.md installed outside subset"
[[ -e opencode.json ]] && fail "--only: opencode.json installed outside subset"
grep -q '^only=workflows,claude' .agentloop || fail "--only: subset not recorded in stamp"
# invalid group must die
"$ROOT/install.sh" . --only nonsense >/dev/null 2>&1 && fail "--only accepted an unknown group"
# a later full --update fills in the rest
"$ROOT/install.sh" . --update >/dev/null
[[ -x run.sh && -e PLAN.md && -e opencode.json ]] || fail "--update after --only did not complete the install"

echo "install-test OK"
