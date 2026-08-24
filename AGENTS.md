# How you work — on agentloop itself

This repository IS the tool. `template/` is the product: everything in it gets
copied into other people's projects by `install.sh`. Treat template changes
with corresponding care.

`PLAN.md` is the source of truth. Each session you are given exactly one item
from it. Do that item, mark it done, record any new work you discovered, open
a pull request, and stop.

## Workflow

1. `git switch -c feat/<short-slug>` — never work directly on `main`.
2. Implement **only** the item you were given.
3. Add or extend tests that prove it works (see Project reference).
4. Run the lint and test commands. Fix failures until green.
5. In `PLAN.md`, change that item's `- [ ]` to `- [x]`.
6. You may append up to 3 newly discovered `- [ ]` items to the end of the
   milestone they belong to, or under `## Discovered`. Append only — never
   delete, reorder or reword existing items.
7. Conventional Commits (`feat:`, `fix:`, `chore:`, `docs:`, `test:`).
   feat/fix drive release-please version bumps — use them accurately.
8. `git push -u origin HEAD` then `gh pr create --fill --label automated`
9. **STOP.** No waiting for CI, no merging, no releases.

## Rules specific to this repo

- **Keep engine parity.** A behaviour change in `template/run.sh` must work
  for both engines (opencode and claude). If it can't, gate it explicitly and
  document why.
- **Keep the file-class lists in install.sh authoritative.** Adding a file to
  `template/` means adding it to `MANAGED_FILES` or `USER_FILES` and asserting
  it in `tests/install-test.sh` — all three in the same PR.
- **Installer must stay macOS bash 3.2 compatible.** No associative arrays,
  no `mapfile`, no `readarray`.
- **Never break released refs.** `install.sh` from an old tag must keep
  working; changes to remote-mode behaviour need a compatibility note in the
  PR description.
- Do not modify `.github/workflows/` (this repo's own CI) — that path is
  guarded, and CI changes are a human decision.
- Never commit secrets. Never weaken tests to pass them.

## When you get stuck

Three failed attempts → commit what you have, open the PR with the `blocked`
label instead of `automated`, describe what you tried, leave the checkbox
unchecked, stop.

## Project reference

- Tests:  `bash tests/install-test.sh`
- Lint:   `shellcheck -S warning install.sh tests/install-test.sh template/run.sh template/setup-github.sh`
- Syntax: `bash -n install.sh tests/install-test.sh template/run.sh template/setup-github.sh`
- JSON:   `python3 -c "import json;[json.load(open(f)) for f in ['template/opencode.json','template/.mcp.json','template/.claude/settings.json']]"`
- Layout: `install.sh` (installer) · `template/` (the product) ·
  `tests/` (installer tests) · `docs/SETUP.md` (user guide) ·
  `version.txt` + `CHANGELOG.md` (release-please owns these — don't edit)
