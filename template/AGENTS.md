# How you work

`PLAN.md` is the source of truth for what this project needs. Each session you
are given exactly one item from it. Do that item, mark it done, record any new
work you discovered along the way, open a pull request, and stop.

## Workflow

1. `run.sh` has already created and switched to a fresh work branch for this
   session. Stay on it — never switch branches, never touch `main`.
2. Implement **only** the item you were given. Do not start other items, do not
   refactor unrelated code, do not "improve things while you're here".
3. Write or extend tests that prove the item works.
4. Run the project's lint and test commands (see Project reference below).
   Fix failures until everything is green. If you changed dependencies
   (pyproject.toml or equivalent), refresh the lockfile (`uv lock`) and
   COMMIT it — CI rejects a stale lockfile.
5. `PLAN.md` on your branch already shows the item ticked — the loop does
   this when it creates the branch. Leave it as is. The tick travels with
   the branch: it reaches `main` only if the PR merges. Only if you end the
   session without completing the item, revert it to `- [ ]` before pushing.
6. Record any new work you discovered — see "Growing the plan" below.
7. Commit using Conventional Commits: `feat:`, `fix:`, `chore:`, `docs:`,
   `refactor:`, `test:`. Small, single-purpose commits. Before committing,
   look at `git status`: NEVER commit generated artifacts — bytecode
   (`__pycache__`, `*.pyc`), tool caches (`.pytest_cache`, `.ruff_cache`,
   `.mypy_cache`), reports, coverage files, build output. If one shows up,
   add it to `.gitignore` in the same commit instead.
8. `git push -u origin HEAD`. If the push is rejected because `main` moved,
   merge `origin/main` into your branch. If `PLAN.md` conflicts, take main's
   version of every line except your own item's tick — never let a conflict
   resolution untick another item (its code is already merged on main).
9. `gh pr create --fill --label automated`
10. **STOP.** Do not wait for CI, do not merge, do not cut a release, do not
    poll the PR, do not start the next item. GitHub handles everything after
    the PR is open.

## Skills

Situational know-how lives in skills: `.agents/skills/<name>/SKILL.md`. Your
engine lists them by name and description; load one when it applies — with
your skill tool, or simply by reading the file. When the prompt names a skill,
load it before you start.

| Skill | Load it when |
|---|---|
| `agentloop-graph-navigation` | Finding where to work; before changing a symbol |
| `agentloop-testing` | Writing tests, or a test is flaky or slow |
| `agentloop-pull-request` | Right before opening the PR, or when you are stuck |
| `agentloop-plan-items` | Writing or appending `PLAN.md` items |
| `agentloop-merge-conflicts` | A push is rejected or a merge conflicts |
| `agentloop-dependencies` | Adding, removing or upgrading a dependency |
| `agentloop-ci-fix` | CI failed on your pull request |
| `agentloop-ci-proposals` | The item is about CI or `.github/workflows/` |
| `agentloop-skill-authoring` | You learned something the next session will need |

`agentloop-*` skills are maintained by agentloop and replaced on every update —
never edit them. Every other skill in that directory belongs to this project;
some were recorded by earlier sessions.

**Record what you learn.** When you work out something non-obvious and
reusable about this project — how to run, test, debug or seed part of it, or a
trap that cost you several attempts — save it as a project skill so the next
session does not rediscover it (`agentloop-skill-authoring`). At most one new
skill per session; prefer updating an existing one. Name it in the PR
description.

## Growing the plan

You are expected to add to `PLAN.md`, not just consume it. While implementing an
item you will often find work the plan does not cover: a missing edge case, a
required migration, error handling that was hand-waved, a refactor a later item
will depend on. Record it instead of silently doing it or silently ignoring it.

- Append new `- [ ]` items to the **end** of the milestone they belong to, or
  under `## Discovered` if you are not sure. Same style as existing items:
  concrete, independently testable, one pull request each
  (`agentloop-plan-items` has the format and examples).
- **Append only.** Never delete, reorder, reword or uncheck an existing item,
  and never touch an item above the one you are working on.
- At most 3 new items per session. If you found nothing, add nothing — do not
  pad the plan to look productive, and leave out what is merely nice to have.
- If something must be done **before** your current item can work, do not
  reorder the plan. Stop, open the PR with the `blocked` label, and explain
  the dependency.
- List what you added and why in the pull request description.

Only a `--replan` session may restructure `PLAN.md` freely.

## Understanding the codebase

This repository has a knowledge graph of itself. **Query the graph before you
read source files** — it is dramatically cheaper than reading files, and it is
how this project stays affordable.

- MCP tools: `graphify_query_graph` (start here), `graphify_get_neighbors`,
  `graphify_shortest_path`, `graphify_god_nodes`, `graphify_get_node`.
- The same graph from any shell: `graphify query "<question>" --budget 1500`,
  `graphify explain "<symbol>"`, `graphify path "<A>" "<B>"`.
- The prompt may already include a "Where to start" excerpt from the graph —
  begin there.

Only open a file once the graph has told you which file and which lines
matter. Edges marked `INFERRED` are guesses — verify them in the source. The
graph reflects the last index, so files you just created are not in it yet.
More in `agentloop-graph-navigation`.

## Output discipline (token budget)

Every byte a command prints is re-sent to the model on every following step.
Waste here compounds into slower sessions, forced context compaction (which
loses detail), and burned request quota.

- Run tests quietly and clip the output: `uv run pytest -q ... 2>&1 | tail -30`.
  Only re-run verbosely for the ONE failing test you are debugging.
- Never dump whole files. `grep -n` to locate, then read only the relevant
  range. Ask the knowledge graph before opening any file at all.
- Never print whole logs, lockfiles, or generated artifacts. `tail`, `head`,
  `wc -l` and targeted `grep` answer almost every question.
- Prefer one command that answers the question over several exploratory ones.
- Performance tests: never assert absolute wall-clock durations — they flake
  on shared CI runners. Assert relative ratios (min-of-runs at microsecond
  scale) or gate absolute checks behind an opt-in env var.

## Prohibited

- No direct pushes to `main` or `release/*`.
- No `git push --force`.
- Do not modify anything under `.github/workflows/`. Plan items about CI are
  delivered as proposals under `ci-proposals/` (`agentloop-ci-proposals`).
- Do not create or edit `agentloop-*` skills.
- Do not restructure `PLAN.md`. You may tick your own item and append new ones
  (see "Growing the plan") — nothing else. If the plan itself is wrong, say so
  in the PR description and stop.
- Do not delete, skip (`skip`/`xfail`) or disable tests to make them pass.
  If a test fails, fix the code — not the test. If a test is genuinely wrong,
  explain why you changed it in the PR description.
- No `terraform apply` or `terraform destroy`. Only `fmt`,
  `init -backend=false`, `validate`, `plan`.
- Never commit secrets, tokens or `.env` contents, and never print
  environment variables into files or logs.
- When adding a new dependency, justify it in the PR description.

## Cross-platform CI

Your sandbox is Linux, but CI may also run Windows, macOS and a minimum
toolchain version. Code that only exists on one platform (unix-only APIs and
their imports, shell/path assumptions, `chmod`) and its tests must carry an
explicit platform guard (e.g. `#[cfg(unix)]`, `sys.platform` checks). A green
local run does not prove the other platforms are green.

## When you get stuck

If you cannot finish the item in 3 attempts, stop pushing on it. Commit what
you have, open the PR with the `blocked` label instead of `automated`, and
write in the description: what you tried, what happened, and what you need.
Leave the `PLAN.md` checkbox unchecked. Then stop.

## Project reference

<!-- Fill this in for your own project. If these commands are wrong, the
     agent runs the wrong thing and wastes turns discovering that. -->

- Tests:        `uv run pytest`
- Lint:         `uv run ruff check .`
- Format:       `uv run ruff format .`
- Dependencies: `uv sync` / `uv add <package>`
- Source:       `src/`
- Tests dir:    `tests/`
- Spark jobs live in `src/jobs/`. Test locally with
  `spark-submit --master local[2] src/jobs/<job>.py`
- Terraform:    `infra/`
