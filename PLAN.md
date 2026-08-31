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

## Discovered

<!-- Work the agent found while building. Promote with ./run.sh --replan. -->

- [ ] Validate --engine codex with a real end-to-end run (bubblewrap bypass inside the container, JSON stream against the live CLI), and evaluate pointing Codex at OpenRouter via model_providers + wire_api="responses" (unverified whether OpenRouter implements the Responses API)
