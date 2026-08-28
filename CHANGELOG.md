# Changelog

## [0.4.0](https://github.com/yildirimarda/agentloop/compare/v0.3.0...v0.4.0) (2026-08-28)


### Features

* keep existing CI untouched and auto-detect the required check name ([dc5e41b](https://github.com/yildirimarda/agentloop/commit/dc5e41b70ec3cba8c8db3e47e9d222efc8d6b62f))

## [0.3.0](https://github.com/yildirimarda/agentloop/compare/v0.2.0...v0.3.0) (2026-08-28)


### Features

* format detection, --replan converter, CHECK passthrough ([b09dcc9](https://github.com/yildirimarda/agentloop/commit/b09dcc90204e1290e855f5a4aa49f8e5bb18ac6e))

## [0.2.0](https://github.com/yildirimarda/agentloop/compare/v0.1.3...v0.2.0) (2026-08-28)


### Features

* detect non-checkbox plans, make --replan the format converter, guide next steps when plan completes ([5e3dd5e](https://github.com/yildirimarda/agentloop/commit/5e3dd5ec638277d04b7e4c690c45a7a15f758c77))

## [0.1.3](https://github.com/yildirimarda/agentloop/compare/v0.1.2...v0.1.3) (2026-08-24)


### Bug Fixes

* restore personalized repo URLs and correct installed-files tree in docs ([e72f2fc](https://github.com/yildirimarda/agentloop/commit/e72f2fce8ed1db307b7071cf7eb031452ab7c169))

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
