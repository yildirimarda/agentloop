# Changelog

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
