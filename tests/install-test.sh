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
  .agents/skills/agentloop-ci-fix/SKILL.md
  .agents/skills/agentloop-ci-proposals/SKILL.md
  .agents/skills/agentloop-dependencies/SKILL.md
  .agents/skills/agentloop-graph-navigation/SKILL.md
  .agents/skills/agentloop-merge-conflicts/SKILL.md
  .agents/skills/agentloop-plan-items/SKILL.md
  .agents/skills/agentloop-pull-request/SKILL.md
  .agents/skills/agentloop-skill-authoring/SKILL.md
  .agents/skills/agentloop-testing/SKILL.md
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
for rule in ("Edit(.agents/skills/agentloop-*/**)", "Write(.agents/skills/agentloop-*/**)", "Edit(.github/workflows/**)"):
    assert rule in d["permissions"]["deny"], "template deny missing: " + rule
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

# Claude Code: tool inputs, MCP status, thinking, failed results; OpenCode skills
cl_out="$(printf '%s\n' \
  '{"type":"system","subtype":"init","model":"claude-sonnet-x","mcp_servers":[{"name":"graphify","status":"connected"}]}' \
  '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"uv run pytest -q"}}]}}' \
  '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/work/src/app.py"}}]}}' \
  '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"agentloop-ci-fix"}}]}}' \
  '{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"The test fails on Windows."}]}}' \
  '{"type":"result","subtype":"error_max_turns","is_error":true,"result":"Reached max turns"}' \
  '{"type":"tool_use","part":{"tool":"skill","state":{"input":{"name":"agentloop-testing"}}}}' \
  | stream_view)"
echo "$cl_out" | grep -q '· claude-sonnet-x · mcp: graphify connected' || fail "stream_view: claude init/MCP status not shown"
echo "$cl_out" | grep -q '→ Bash: uv run pytest -q'          || fail "stream_view: claude Bash command not shown"
echo "$cl_out" | grep -q '→ Read: /work/src/app.py'          || fail "stream_view: claude file path not shown"
echo "$cl_out" | grep -q '→ Skill: agentloop-ci-fix'         || fail "stream_view: claude skill load not shown"
echo "$cl_out" | grep -q '⋯ The test fails on Windows.'      || fail "stream_view: claude thinking not shown"
echo "$cl_out" | grep -q '✖ Reached max turns'               || fail "stream_view: claude failed result not shown"
echo "$cl_out" | grep -q '→ skill: agentloop-testing'        || fail "stream_view: opencode skill load not shown"

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

# ── 13. Token-budget config landed intact ─────────────────────────────────────
cd "$TMP/proj"
grep -q -- "--headroom" run.sh || fail "run.sh lacks --headroom flag"
grep -q "OPENCODE_CONFIG_CONTENT" run.sh || fail "run.sh lacks headroom config override"
# ── 13b. Failure handling, watchdog, NVIDIA wiring ───────────────────────────
grep -q "NVIDIA_API_KEY" run.sh      || fail "run.sh lacks NVIDIA_API_KEY passthrough"
grep -q -- "--stall-timeout" run.sh  || fail "run.sh lacks --stall-timeout"
grep -q "agentloop.run" run.sh       || fail "run.sh does not label its containers"
./run.sh --help | grep -q -- "--stall-timeout" || fail "--help does not document --stall-timeout"
# keep_branch_and_return: back on main, branch kept, dirty leftovers stashed
mkdir -p "$TMP/kb" && cd "$TMP/kb"
git init -q -b main . && git commit -q --allow-empty -m init
git switch -q -c agent/demo && echo x > f.txt && git add f.txt && git commit -q -m work && echo y > dirty.txt
# shellcheck disable=SC2034  # read and set by the eval'd keep_branch_and_return
BASE_BRANCH=main MODE=plan KEPT_BRANCH=""
eval "$(sed -n '/^keep_branch_and_return()/,/^}$/p' "$TMP/proj/run.sh")"
kb_out="$(keep_branch_and_return "CI failing" 7)"
[[ "$(git rev-parse --abbrev-ref HEAD)" == "main" ]] || fail "keep_branch_and_return: not back on main"
git rev-parse --verify -q agent/demo >/dev/null     || fail "keep_branch_and_return: work branch was deleted"
[[ -z "$(git status --porcelain)" ]]                || fail "keep_branch_and_return: tree not clean"
[[ -n "$(git stash list)" ]]                        || fail "keep_branch_and_return: leftovers not stashed"
echo "$kb_out" | grep -q "git switch agent/demo"    || fail "keep_branch_and_return: missing inspect hint"
echo "$kb_out" | grep -q "start again from main" || fail "keep_branch_and_return: missing restart hint"
echo "$kb_out" | grep -q "gh pr close 7"            || fail "keep_branch_and_return: missing PR close hint"
echo "$kb_out" | grep -q "./run.sh --resume agent/demo all" || fail "keep_branch_and_return: missing resume-all hint"
echo "$kb_out" | grep -q "re-applies the stashed leftovers"  || fail "keep_branch_and_return: resume hint does not mention the stash"
# ci_fail_log: per-job log, noise stripped, retried when the first pass is empty
mkdir -p "$TMP/cf" && cd "$TMP/cf"
info() { echo "  $*"; }
sleep() { :; }
CF_CALLS="$TMP/cf/calls"; : > "$CF_CALLS"
gh_c() {
  case "$*" in
    "pr view 9 --json headRefOid -q .headRefOid") echo abc123 ;;
    api*) echo x >> "$CF_CALLS"; [[ "$(wc -l < "$CF_CALLS")" -ge 2 ]] && printf '41\trust\n' ;;
    "run view 41 --json jobs"*) printf '77\trust (windows-latest)\n' ;;
    "run view --job 77 --log-failed")
      printf 'rust (windows-latest)\tUNKNOWN STEP\t2026-10-30T11:30:30.8Z error: unused imports: `Arch`\n'
      printf 'rust (windows-latest)\tUNKNOWN STEP\t2026-10-30T11:30:34.9Z Post job cleanup.\n'
      printf 'rust (windows-latest)\tUNKNOWN STEP\t2026-10-30T11:30:35.2Z git version 2.56.0.windows.2\n' ;;
  esac
}
eval "$(sed -n '/^_clean_job_log()/,/^}$/p;/^_ci_fail_log_once()/,/^}$/p;/^ci_fail_log()/,/^}$/p' "$TMP/proj/run.sh")"
cf_out="$(ci_fail_log 9 2>/dev/null)"
echo "$cf_out" | grep -q "FAILED JOB: rust / rust (windows-latest)" || fail "ci_fail_log: job header missing (empty first pass not retried?)"
echo "$cf_out" | grep -q 'error: unused imports: `Arch`'          || fail "ci_fail_log: compiler error missing"
echo "$cf_out" | grep -q "UNKNOWN STEP"                             && fail "ci_fail_log: column prefix not stripped"
echo "$cf_out" | grep -q "git version"                              && fail "ci_fail_log: post-job cleanup noise not cut"
ls "$TMP"/cf/logs/*-cifail.txt >/dev/null 2>&1                      || fail "ci_fail_log: no trace file written"
unset -f gh_c sleep info
cd "$TMP/proj"

# require_secret: a missing keychain entry must stop the run in the MAIN shell
# (a die inside "$(...)" only ends the subshell and the run went on with an
# empty token), and a present one is assigned without a subshell.
rs_out="$(
  eval "$(sed -n '/^die()/p;/^secret_env_name()/,/^}$/p;/^secret_optional()/,/^}$/p;/^require_secret()/,/^}$/p' run.sh)"
  security() { [[ "$3" == "present" ]] && echo "s3cret" || return 44; }
  require_secret GOT present
  echo "got=$GOT"
  require_secret NOPE missing-entry 2>/dev/null
  echo "SHOULD-NOT-REACH"
)" && fail "require_secret: missing secret did not exit non-zero"
echo "$rs_out" | grep -q "got=s3cret"        || fail "require_secret: present secret not assigned"
echo "$rs_out" | grep -q "SHOULD-NOT-REACH"  && fail "require_secret: run continued after a missing secret"
grep -q 'mktemp -t' run.sh && fail "run.sh uses BSD-only 'mktemp -t' (breaks on GNU/Linux)"

# ensure_automerge_label: bash (not the model) guarantees the "automated"
# label, and a PR the agent flagged for a human is reported instead of waited on.
(
  eval "$(sed -n '/^info()/p;/^pr_labels()/p;/^ensure_automerge_label()/,/^}$/p' run.sh)"
  PR_FLAG=""
  EDITS="$TMP/label-edits"; : > "$EDITS"
  gh_c() {
    case "$*" in
      "pr view "*"--json labels"*) printf '%s\n' $FAKE_LABELS ;;
      "pr edit "*) echo "$*" >> "$EDITS" ;;
    esac
  }
  FAKE_LABELS="" ensure_automerge_label 5 >/dev/null || fail "label: unlabelled PR reported as flagged"
  grep -q "pr edit 5 --add-label automated" "$EDITS" || fail "label: 'automated' not added to an unlabelled PR"
  : > "$EDITS"
  FAKE_LABELS="automated" ensure_automerge_label 6 >/dev/null || fail "label: automated PR reported as flagged"
  [[ -s "$EDITS" ]] && fail "label: relabelled a PR that already had 'automated'"
  FAKE_LABELS="automated blocked" ensure_automerge_label 7 >/dev/null && fail "label: blocked PR not reported"
  [[ "$PR_FLAG" == "blocked" ]] || fail "label: PR_FLAG not set to blocked"
  FAKE_LABELS="plan" ensure_automerge_label 8 >/dev/null && fail "label: plan-labelled item PR not reported"
  exit 0
) || exit 1
grep -q 'PROT_RC=\$?' setup-github.sh || fail "setup-github.sh lost the branch-protection status capture"
awk '/PROT_RC=\$\?/{found=NR} /gh api -X PUT/{api=NR} END{exit !(found>api && found-api<25)}' setup-github.sh \
  || fail "setup-github.sh: PROT_RC must be captured right after the protection API call"

python3 -c "
import json
d = json.load(open('opencode.json'))
assert d['compaction']['prune'] is True
assert d['tool_output']['max_lines'] == 500
assert d['provider']['openrouter']['options']['setCacheKey'] is True
" || fail "opencode.json token-budget settings missing"
grep -q "Output discipline" AGENTS.md || fail "AGENTS.md lacks output-discipline section"

# ── 13a. Git guard: force/delete/main pushes and leaked secrets are refused ──
mkdir -p "$TMP/gg" && cd "$TMP/gg"
git init -q --bare remote.git
git clone -q remote.git work 2>/dev/null && cd work
git symbolic-ref HEAD refs/heads/main
git commit -q --allow-empty -m init && git push -q origin main 2>/dev/null
mkdir -p logs
(
  # shellcheck disable=SC2034  # REPO_DIR is read by the eval'd write_git_guard
  REPO_DIR="$PWD"; GUARD_MOUNT=""
  eval "$(sed -n '/^write_git_guard()/,/^}$/p' "$TMP/proj/run.sh")"
  write_git_guard
  [[ "$GUARD_MOUNT" == "$PWD/logs/.git-guard:/usr/local/sbin/git:ro" ]] || fail "git guard: wrong mount spec: $GUARD_MOUNT"
) || exit 1
G="$PWD/logs/.git-guard"
[[ -x "$G" ]] || fail "git guard: not written/executable"
refused() { if "$G" "$@" >/dev/null 2>&1; then fail "git guard let through: git $*"; fi; }
"$G" status >/dev/null || fail "git guard: non-push command not passed through"
refused push origin main            # on main
refused push -u origin HEAD         # HEAD is main
git switch -q -c agent/work && echo ok > f.txt && git add f.txt && git commit -qm work
refused push --force origin HEAD
refused push -f origin HEAD
refused push -uf origin HEAD
refused push origin +HEAD
refused push origin HEAD:main
refused push origin agent/work:refs/heads/master
refused push origin :agent/work
refused push --delete origin agent/work
refused -C "$PWD" push --force origin HEAD
"$G" push -q -u origin HEAD 2>/dev/null || fail "git guard: refused a normal work-branch push"
git --git-dir=../remote.git rev-parse -q --verify refs/heads/agent/work >/dev/null || fail "git guard: normal push did not reach the remote"
# routes to main the command line does not spell out: --all, wildcards,
# push config, aliases — with local main ahead of the remote, each would move it
git switch -q main && git commit -q --allow-empty -m "local main commit" && git switch -q agent/work
refused push --all origin
refused push origin 'refs/heads/*:refs/heads/*'
refused -c push.default=matching push origin
refused -c remote.origin.push=main:main push origin
refused -c alias.p=push p origin main
[[ "$(git --git-dir=../remote.git rev-parse main)" == "$(git rev-parse main~1)" ]] || fail "git guard: remote main moved"
"$G" push -q origin HEAD 2>/dev/null || fail "git guard: refused a plain push of the work branch"
# the guard must find the real git even when its own directory is on PATH
# under another spelling (trailing slash) — no exec loop
if command -v timeout >/dev/null 2>&1; then
  mkdir -p "$TMP/ggbin" && cp "$G" "$TMP/ggbin/git"
  timeout 10 env PATH="$TMP/ggbin/:$PATH" "$TMP/ggbin/git" --version >/dev/null \
    || fail "git guard: could not find the real git past itself on PATH"
fi
export OPENROUTER_API_KEY="sk-or-v1-testsecretvalue0123456789"
echo "key=$OPENROUTER_API_KEY" > leaked.txt && git add leaked.txt && git commit -qm "oops"
gg_err="$("$G" push origin HEAD 2>&1)" && fail "git guard: pushed a commit containing a secret"
echo "$gg_err" | grep -q 'OPENROUTER_API_KEY' || fail "git guard: secret refusal does not name the variable"
echo "$gg_err" | grep -q 'testsecretvalue'    && fail "git guard: refusal message leaked the secret itself"
unset OPENROUTER_API_KEY
"$G" push -q origin HEAD 2>/dev/null || fail "git guard: push refused once the secret is gone from the env"
cd "$TMP/proj"

# ── 13b'. Item details: indented lines under the next item ───────────────────
(
  eval "$(sed -n '/^plan_details()/,/^}$/p' run.sh)"
  PLAN="$TMP/details-plan.md"
  printf '%s\n' '# Plan' '- [x] done item' '  - detail of a DONE item' \
    '- [ ] next item' '  - limit 5 per minute' '	- tab-indented detail' '    - nested detail' \
    '  - [ ] nested checkbox ends the details' '  - not reached' > "$PLAN"
  got="$(plan_details)"
  [[ "$got" == "$(printf '%s\n' '- limit 5 per minute' '- tab-indented detail' '  - nested detail')" ]] \
    || fail "plan_details: unexpected details: [$got]"
  printf '%s\n' '- [ ] item' '  - first' '' '  - after a blank line' > "$PLAN"
  [[ "$(plan_details)" == "- first" ]] || fail "plan_details: a blank line must end the details"
  printf '%s\n' '- [ ] item' 'not indented' > "$PLAN"
  [[ -z "$(plan_details)" ]] || fail "plan_details: an unindented line is not a detail"
  exit 0
) || exit 1

# ── 13c. Skills: shipped, valid, listed, owned correctly ─────────────────────
# Every template skill directory is registered in install.sh (and vice versa)
# and passes the same checks the engines apply (name = dir, description).
for d in "$ROOT"/template/.agents/skills/*/; do
  s="$(basename "$d")"
  grep -q "^  .agents/skills/$s/SKILL.md$" "$ROOT/install.sh" || fail "skill $s is not in install.sh MANAGED_FILES"
done
(
  eval "$(sed -n '/^skill_field()/,/^}$/p;/^skill_problems()/,/^}$/p' run.sh)"
  for f in "$ROOT"/template/.agents/skills/*/SKILL.md; do
    probs="$(skill_problems "$f")"
    [[ -z "$probs" ]] || fail "template skill $f: $probs"
    case "$(basename "$(dirname "$f")")" in agentloop-*) : ;; *) fail "template skill without agentloop- prefix: $f" ;; esac
    lines="$(wc -l < "$f" | tr -d ' ')"
    (( lines <= 120 )) || fail "template skill $f has $lines lines — keep skills short (progressive disclosure)"
  done
  exit 0
) || exit 1
sk_out="$(./run.sh --skills)" || fail "run.sh --skills failed on a fresh install"
echo "$sk_out" | grep -q "agentloop-ci-fix" || fail "--skills does not list agentloop-ci-fix"
# a malformed project skill is flagged (and makes --skills exit 1)
mkdir -p .agents/skills/Bad_Skill && printf '%s\n' '---' 'name: other' '---' 'body' > .agents/skills/Bad_Skill/SKILL.md
if ./run.sh --skills > "$TMP/sk.txt" 2>&1; then fail "--skills accepted a malformed skill"; fi
grep -q "does not match its directory" "$TMP/sk.txt" || fail "--skills did not explain the name mismatch"
rm -rf .agents/skills/Bad_Skill
# a managed skill is refreshed on --update; a project skill is never touched
echo "tamper" >> .agents/skills/agentloop-testing/SKILL.md
mkdir -p .agents/skills/run-db && printf '%s\n' '---' 'name: run-db' 'description: Start the local db.' '---' > .agents/skills/run-db/SKILL.md
"$ROOT/install.sh" . --update >/dev/null
grep -q "^tamper" .agents/skills/agentloop-testing/SKILL.md && fail "--update did not refresh a managed skill"
[[ -f .agents/skills/run-db/SKILL.md ]] || fail "--update touched a project skill"
# --only skills installs the skills and nothing else
mkdir -p "$TMP/onlysk" && (cd "$TMP/onlysk" && git init -q . && git commit -q --allow-empty -m init \
  && "$ROOT/install.sh" . --only skills >/dev/null) || fail "--only skills failed"
[[ -f "$TMP/onlysk/.agents/skills/agentloop-ci-fix/SKILL.md" ]] || fail "--only skills: skills missing"
[[ -e "$TMP/onlysk/run.sh" ]] && fail "--only skills installed run.sh"
# an untouched skeleton PLAN.md follows the template on --update (so --init
# still recognises it); a plan someone wrote in is never touched
mkdir -p "$TMP/skel" && (cd "$TMP/skel" && git init -q . && git commit -q --allow-empty -m init \
  && "$ROOT/install.sh" . >/dev/null) || fail "skeleton test: install failed"
cp -R "$ROOT" "$TMP/src3" && printf '%s\n' '' '<!-- a newer skeleton -->' >> "$TMP/src3/template/PLAN.md"
"$TMP/src3/install.sh" "$TMP/skel" --update >/dev/null || fail "skeleton test: update failed"
grep -q "a newer skeleton" "$TMP/skel/PLAN.md" || fail "--update did not refresh an untouched skeleton PLAN.md"
init_out="$(cd "$TMP/skel" && ./run.sh --init "x" 2>&1 || true)"
echo "$init_out" | grep -q "untouched installer skeleton" || fail "--init no longer recognises the skeleton after --update"
echo "- [ ] my real item" >> "$TMP/skel/PLAN.md"
printf '%s\n' '<!-- newer still -->' >> "$TMP/src3/template/PLAN.md"
"$TMP/src3/install.sh" "$TMP/skel" --update >/dev/null || fail "skeleton test: second update failed"
grep -q "my real item" "$TMP/skel/PLAN.md" || fail "--update overwrote a PLAN.md someone wrote in"
grep -q "newer still" "$TMP/skel/PLAN.md" && fail "--update templated over an edited PLAN.md"
# an agentloop-new copy of a skill (depth 4) is removed by --uninstall too
mkdir -p "$TMP/skel/.agents/skills/agentloop-testing" && echo x > "$TMP/skel/.agents/skills/agentloop-testing/SKILL.md.agentloop-new"
"$ROOT/install.sh" "$TMP/skel" --uninstall >/dev/null
[[ -e "$TMP/skel/.agents/skills/agentloop-testing/SKILL.md.agentloop-new" ]] && fail "--uninstall left a skill's .agentloop-new"
# an older template without skills (installer from main + --ref <old tag>)
cp -R "$ROOT" "$TMP/oldsrc" && rm -rf "$TMP/oldsrc/template/.agents"
mkdir -p "$TMP/oldref" && (cd "$TMP/oldref" && git init -q . && git commit -q --allow-empty -m init)
old_out="$("$TMP/oldsrc/install.sh" "$TMP/oldref")" || fail "install from a template without skills failed"
echo "$old_out" | grep -q "skipped    .agents/skills/agentloop-ci-fix/SKILL.md" || fail "missing template file not reported as skipped"
[[ -x "$TMP/oldref/run.sh" ]] || fail "install from an older template did not install run.sh"
# --uninstall removes agentloop's skills, keeps the project's
"$ROOT/install.sh" . --uninstall >/dev/null
[[ -e .agents/skills/agentloop-ci-fix ]] && fail "--uninstall left an agentloop skill directory"
[[ -f .agents/skills/run-db/SKILL.md ]] || fail "--uninstall removed a project skill"
"$ROOT/install.sh" "$TMP/onlysk" --uninstall >/dev/null
[[ -e "$TMP/onlysk/.agents" ]] && fail "--uninstall left an empty .agents/ behind"
"$ROOT/install.sh" . >/dev/null 2>&1 || fail "reinstall after skills uninstall failed"

# ── 13d. Rate-limit arithmetic ───────────────────────────────────────────────
# shellcheck disable=SC2034  # read by the eval'd functions
RPM=0 RPD=0 TPM=0 TPD=0 ITPM=0 OTPM=0
# shellcheck disable=SC2034  # set and read by the eval'd rate functions
RATE_WHY=""
mkdir -p "$TMP/rate" && cd "$TMP/rate"
RATE_LEDGER="$TMP/rate/ledger"
eval "$(sed -n '/^rate_wait_for()/,/^}$/p;/^rate_wait_secs()/,/^}$/p' "$TMP/proj/run.sh")"
now="$(date +%s)"
printf '%s\n' "$((now - 50)) 100 10" "$((now - 20)) 300 30" > "$RATE_LEDGER"
w="$(rate_wait_for req 60 2 1)"
[[ "$w" -ge 10 && "$w" -le 12 ]] || fail "rate: 2 requests in the last minute, RPM 2 — expected ~11s, got $w"
[[ "$(rate_wait_for req 60 3 1)" == 0 ]] || fail "rate: RPM 3 still has room for one more"
[[ "$(rate_wait_for in 60 500 150)" -gt 0 ]] || fail "rate: 400 input tokens + 150 expected must wait under ITPM 500"
[[ "$(rate_wait_for in 60 600 150)" == 0 ]] || fail "rate: ITPM 600 fits 400 + 150"
[[ "$(rate_wait_for out 60 40 20)" -gt 0 ]] || fail "rate: OTPM 40 cannot fit 40 + 20"
[[ "$(rate_wait_for tok 60 100 500)" == 0 ]] || fail "rate: one request larger than the limit must not wait forever"
# shellcheck disable=SC2034  # read by the eval'd rate_wait_secs
RPM=0
# shellcheck disable=SC2034
TPM=450
r="$(rate_wait_secs 100 50)"
[[ "${r%%|*}" -gt 0 && "${r#*|}" == "TPM (450)" ]] || fail "rate: wait_secs gave '$r'"
: > "$RATE_LEDGER"
[[ "$(rate_wait_secs 1 1)" == "0|" ]] || fail "rate: an empty ledger must never wait"
# Cached prompt tokens: what each engine's usage event adds up to in the ledger.
if command -v jq >/dev/null 2>&1; then
  eval "$(sed -n '/^rate_gate()/,/^}$/p' "$TMP/proj/run.sh")"
  rate_record() { echo "$1 $2" >> "$TMP/rate/seen"; }
  rate_hold() { :; }
  gate_lines() {   # RATE_CACHE value; stdin = engine events → prints "in out" per request
    # shellcheck disable=SC2034  # read by the eval'd rate_gate
    RATE_CACHE="$1"; : > "$TMP/rate/seen"; rate_gate >/dev/null; cat "$TMP/rate/seen"
  }
  oc='{"type":"step_finish","part":{"tokens":{"input":100,"output":50,"cache":{"read":5000,"write":200},"total":5350}}}'
  cx='{"type":"turn.completed","usage":{"input_tokens":6000,"cached_input_tokens":5000,"output_tokens":40}}'
  cl='{"type":"assistant","message":{"id":"m1","usage":{"input_tokens":10,"cache_read_input_tokens":4000,"cache_creation_input_tokens":300,"output_tokens":20}}}'
  ol='{"type":"step_finish","part":{"tokens":{"total":900}}}'
  [[ "$(printf '%s\n' "$oc" | gate_lines 1)" == "5300 50" ]] || fail "rate cache: opencode cache read+write must count as input"
  [[ "$(printf '%s\n' "$oc" | gate_lines 0)" == "100 50"  ]] || fail "rate cache: RATE_CACHE=0 must ignore opencode cache tokens"
  [[ "$(printf '%s\n' "$cx" | gate_lines 1)" == "6000 40" ]] || fail "rate cache: codex input already includes the cache"
  [[ "$(printf '%s\n' "$cx" | gate_lines 0)" == "1000 40" ]] || fail "rate cache: RATE_CACHE=0 must subtract codex cached tokens"
  [[ "$(printf '%s\n' "$cl" | gate_lines 1)" == "4310 20" ]] || fail "rate cache: claude cache read+creation must count as input"
  [[ "$(printf '%s\n' "$cl" | gate_lines 0)" == "10 20"   ]] || fail "rate cache: RATE_CACHE=0 must ignore claude cache tokens"
  [[ "$(printf '%s\n' "$ol" | gate_lines 1)" == "900 0"   ]] || fail "rate cache: a total-only event must still be recorded"
  unset -f rate_record rate_hold gate_lines rate_gate
  # Transient provider errors: which session endings are worth a retry.
  eval "$(sed -n '/^session_transient_error()/,/^}$/p' "$TMP/proj/run.sh")"
  mkdir -p "$TMP/ste"
  ste() {   # LOG CONTENT → "code|message|retry-after" or "no"
    printf '%s\n' "$1" > "$TMP/ste/log"
    session_transient_error "$TMP/ste/log" | tr '\t' '|' || echo no
  }
  [[ "$(ste '{"type":"step_start"}
{"type":"error","error":{"name":"APIError","data":{"message":"Too Many Requests","statusCode":429,"isRetryable":true,"responseHeaders":{"retry-after":"7"}}}}')" == "429|Too Many Requests|7" ]] \
    || fail "transient: a 429 with retry-after must be retried and report the header"
  [[ "$(ste '{"type":"error","error":{"name":"APIError","data":{"message":"Cannot connect to API","isRetryable":true}}}')" == "error|Cannot connect to API|0" ]] \
    || fail "transient: a retryable connection error must be retried"
  [[ "$(ste '{"type":"error","error":{"name":"UnknownError","data":{"message":"The operation timed out."}}}')" == "error|The operation timed out.|0" ]] \
    || fail "transient: a timeout must be retried"
  [[ "$(ste '{"type":"result","is_error":true,"result":"API Error: 529 overloaded"}')" == "error|API Error: 529 overloaded|0" ]] \
    || fail "transient: claude's overloaded result must be retried"
  [[ "$(ste '{"type":"error","error":{"data":{"message":"Unauthorized","statusCode":401,"isRetryable":false}}}')" == no ]] \
    || fail "transient: an auth error must NOT be retried"
  [[ "$(ste '{"type":"error","error":{"data":{"message":"Insufficient credits","statusCode":402}}}')" == no ]] \
    || fail "transient: a billing error must NOT be retried"
  [[ "$(ste '{"type":"error","error":{"data":{"message":"x","statusCode":429,"isRetryable":true}}}
{"type":"step_finish","part":{"tokens":{"total":5}}}')" == no ]] \
    || fail "transient: an error the session recovered from is not a reason to retry"
  [[ "$(ste '{"type":"result","is_error":true,"result":"Reached max turns"}')" == no ]] \
    || fail "transient: max turns is not a provider hiccup"
  [[ "$(ste '{"type":"error","error":{"message":"push failed"}}')" == no ]] \
    || fail "transient: an arbitrary failure must NOT be retried"
  [[ "$(ste 'garbage
{"type":"step_fin')" == no ]] || fail "transient: a truncated log must not match"
  unset -f ste session_transient_error
fi
cd "$TMP"

# ── 14. The loop itself, end to end ──────────────────────────────────────────
# Stubbed docker/gh/keychain/engine, real git against a bare "GitHub" repo.
# Chained from here so CI runs it without a workflow change.
bash "$ROOT/tests/loop-test.sh" >/dev/null || fail "loop-test failed (details above; rerun: bash tests/loop-test.sh)"

echo "install-test OK"
