# Plan

<!-- agentloop's own roadmap. This repo dogfoods itself:
       ./install.sh . && ./run.sh
     installs the loop into this repo and works through the items below. -->

## Milestone 1: Hardening

- [x] Extend tests/install-test.sh with a --dry-run assertion suite covering every managed and user file action
- [x] Raise shellcheck severity from error to warning in CI and fix every finding in install.sh, tests/install-test.sh, template/run.sh and template/setup-github.sh
- [x] Add an --uninstall flag to install.sh that removes managed files and the .agentloop stamp while leaving user files untouched, with a test

## Milestone 2: Engines

- [x] Document the engine contract in docs/ENGINES.md: required inputs (prompt, model override), expected log format for the tool-usage summary, exit-code semantics, and how run.sh verifies results independently of the engine
- [x] Add Codex CLI as a third engine (--engine codex) implementing the documented contract (note: Codex has no per-command deny mechanism — documented in docs/ENGINES.md; GitHub-side guards carry enforcement)
- [x] Add per-engine smoke tests that validate the tool-usage jq parsers against recorded fixture logs

## Milestone 3: Loop UX

- [x] Add an --auto-replan option: when -n all exhausts the plan, run one replan session to propose the next wave of items, open the plan-labelled PR, and stop for human review

## Milestone 4: Installer UX

- [x] Add install.sh --check: report installed version vs newest release tag without changing any files
- [x] Print a unified diff summary for every *.agentloop-new file at the end of an --update run
- [x] Support installing a template subset via --only (e.g. --only workflows,claude) for repos that already have parts of the setup

## Milestone 5: Skills and loop intelligence

- [x] Ship portable Agent Skills in template/.agents/skills (agentloop-* managed) visible to all three engines, with prompts naming the skill a session needs and a `skills` install group
- [x] Let sessions record project skills, report new ones after each merge, list/validate them with --skills, and disable recording with --no-learn
- [x] Pass indented item details under a PLAN.md item to its session as acceptance criteria
- [x] Seed item and task prompts with the knowledge graph's answer for the task (graphify query)
- [x] Add an engine-independent git guard in every container: no force pushes, no pushes to main/master, no pushes carrying a secret
- [x] Add --fallback-models: switch models and redo the item when a session yields nothing
- [x] Record logs/history.tsv per item and summarise it per engine/model with --stats
- [x] Add --stop, --max-cost and --notify for unattended runs
- [x] Add --doctor (every run precondition, model availability and free quota) and --build (stale-image detection)
- [x] Add --issue N and --address-review N with a maintainers-only trust gate for GitHub text
- [x] Read secrets from environment variables where the macOS keychain is missing
- [x] Add an end-to-end loop test with stubbed docker, gh, keychain and engine

## Milestone 6: Next

- [x] Detect the default branch instead of hardcoding main in run.sh, setup-github.sh and the git guard
  - BASE_BRANCH from `git symbolic-ref refs/remotes/origin/HEAD`, overridable in .agentloop.local
  - loop-test scenario with a repository whose default branch is master
- [x] Add a local verify gate: VERIFY_CMD runs in the container after a session and a red result gets one local fix session before CI
  - output clipped like CI logs; skipped when VERIFY_CMD is unset
- [x] Add --watch: when the plan is empty, poll main every N minutes and continue as soon as new items land
- [x] Route single items to another engine or model with a detail line (e.g. "engine: claude", "model: vendor/x")
- [x] Add an optional --review session: a second model reviews the PR diff and requests changes before the PR is labelled automated
- [x] When a session committed but opened no PR, push and open it from bash with the blocked label instead of stopping
- [ ] Add Edit/Write deny rules for .agents/skills/agentloop-*/** to template/.claude/settings.json and assert them in tests/install-test.sh
- [ ] Add Gemini CLI as a fourth engine per docs/ENGINES.md, with stream fixtures recorded from a real session

## Discovered

<!-- Work the agent found while building. Promote with ./run.sh --replan. -->

- [ ] Validate --engine codex with a real end-to-end run (bubblewrap bypass inside the container, JSON stream against the live CLI), and evaluate pointing Codex at OpenRouter via model_providers + wire_api="responses" (unverified whether OpenRouter implements the Responses API)
