# Changelog

## [0.1.2](https://github.com/yildirimarda/agentloop/compare/v0.1.1...v0.1.2) (2026-08-24)


### Bug Fixes

* keep installer help in sync and make template CI green on empty repos ([bc2646f](https://github.com/yildirimarda/agentloop/commit/bc2646fb1c15555d5f289673c94b5a92fb2bdd2c))

## [0.1.1](https://github.com/yildirimarda/agentloop/compare/v0.1.0...v0.1.1) (2026-08-24)


### Bug Fixes

* set git identity in test suite so CI runners can commit ([2ed4a19](https://github.com/yildirimarda/agentloop/commit/2ed4a1900443706b59d08b486720b6443c005ba5))

## 0.1.0 (2026-08-23)

Initial release.

- Plan-driven autonomous loop (`run.sh`): deterministic item selection,
  merge-waiting, repo-state verification, discovery with growth cap
- Two engines: OpenCode + OpenRouter free models (default), Claude Code +
  Anthropic (`--engine claude`) with per-session cost reporting
- Graphify knowledge-graph integration over MCP for both engines
- Docker sandbox with git/gh/uv/terraform/java/spark toolchain
- Fully containerized GitHub access: agent pushes, PR polling and repo setup
  (`run.sh --github-setup`) all run in-container with keychain tokens — the
  host needs no gh login or GitHub credentials
- GitHub side: branch protection, auto-merge, release-please, labels
- Installer with managed/user file classes, `--update`, `--ref` pinning,
  `--model` flags, `--dry-run`
