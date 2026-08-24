#!/usr/bin/env bash
# Installer test suite. Run from anywhere: bash tests/install-test.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

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

# ── 8. Merges are idempotent ──────────────────────────────────────────────────
"$ROOT/install.sh" . --update >/dev/null 2>&1
n="$(grep -c '^@AGENTS.md' CLAUDE.md)"
[[ "$n" == "1" ]] || fail "CLAUDE.md import duplicated on re-run (count=$n)"
python3 - <<'PY' || fail "mcp merge not idempotent"
import json
d = json.load(open(".mcp.json"))
assert set(d["mcpServers"]) == {"mydb", "graphify"}, sorted(d["mcpServers"])
PY

echo "install-test OK"
