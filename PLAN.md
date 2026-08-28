# Plan

<!-- agentloop's own roadmap. This repo dogfoods itself:
       ./install.sh . && ./run.sh
     installs the loop into this repo and works through the items below. -->

## Milestone 1: Hardening

- [ ] Extend tests/install-test.sh with a --dry-run assertion suite covering every managed and user file action
- [ ] Raise shellcheck severity from error to warning in CI and fix every finding in install.sh, tests/install-test.sh, template/run.sh and template/setup-github.sh
- [ ] Add an --uninstall flag to install.sh that removes managed files and the .agentloop stamp while leaving user files untouched, with a test

## Milestone 2: Engines

- [ ] Document the engine contract in docs/ENGINES.md: required inputs (prompt, model override), expected log format for the tool-usage summary, exit-code semantics, and how run.sh verifies results independently of the engine
- [ ] Add Codex CLI as a third engine (--engine codex) implementing the documented contract, including its own guardrail config file in the template
- [ ] Add per-engine smoke tests that validate the tool-usage jq parsers against recorded fixture logs

## Milestone 3: Loop UX

- [ ] Add an --auto-replan option: when -n all exhausts the plan, run one replan session to propose the next wave of items, open the plan-labelled PR, and stop for human review

## Milestone 4: Installer UX

- [ ] Add install.sh --check: report installed version vs newest release tag without changing any files
- [ ] Print a unified diff summary for every *.agentloop-new file at the end of an --update run
- [ ] Support installing a template subset via --only (e.g. --only workflows) for repos that already have parts of the setup

## Discovered

<!-- Work the agent found while building. Promote with ./run.sh --replan. -->
