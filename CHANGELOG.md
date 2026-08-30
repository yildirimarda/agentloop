# Changelog

## [0.8.0](https://github.com/yildirimarda/agentloop/compare/v0.7.0...v0.8.0) (2026-08-30)


### Features

* auto-retry failed CI by feeding the failing log back to the agent (--ci-retries) ([565a86f](https://github.com/yildirimarda/agentloop/commit/565a86f479b851971bb18d0f47ea4ade2a815e8a))

## [0.7.0](https://github.com/yildirimarda/agentloop/compare/v0.6.1...v0.7.0) (2026-08-29)


### Features

* create the work branch in bash so the agent can never dirty main ([92cd6b4](https://github.com/yildirimarda/agentloop/commit/92cd6b454a511fc9b3efe87d37484f16ec67f924))

## [0.6.1](https://github.com/yildirimarda/agentloop/compare/v0.6.0...v0.6.1) (2026-08-28)


### Bug Fixes

* pre-create volume mount points in agent image — fresh volumes were root-owned (EACCES) ([96cf3cf](https://github.com/yildirimarda/agentloop/commit/96cf3cf4659118a57480ecc388e3be7e64d6bfe0))

## [0.6.0](https://github.com/yildirimarda/agentloop/compare/v0.5.1...v0.6.0) (2026-08-28)


### Features

* support multiple required status checks (comma-separated CHECK) ([09ead3c](https://github.com/yildirimarda/agentloop/commit/09ead3c7d925738f4a350b44e66c9c0e554307ca))

## [0.5.1](https://github.com/yildirimarda/agentloop/compare/v0.5.0...v0.5.1) (2026-08-28)


### Bug Fixes

* read CI verdict via Actions API; document required Actions permissions and setup order ([26db55d](https://github.com/yildirimarda/agentloop/commit/26db55d671ba6cfb5f4b08eb478784864e6ca704))

## [0.5.0](https://github.com/yildirimarda/agentloop/compare/v0.4.0...v0.5.0) (2026-08-28)


### Features

* let the agent propose CI changes via ci-proposals/ instead of touching workflows ([39b4591](https://github.com/yildirimarda/agentloop/commit/39b4591cbeb71078c471914bf88e98537eaa5250))

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
