# agentloop

A plan-driven autonomous development loop you install into any repository.
The agent reads `PLAN.md`, takes the next unfinished item, implements it inside
a Docker sandbox, runs the project's own tests, opens a pull request, and
stops. CI gates the merge; GitHub merges and releases. Then the loop takes the
next item — including items the agent discovered and added itself.

Three engines behind one flag: **OpenCode + free OpenRouter models**
(default), **Claude Code + Anthropic models** (`--engine claude`), or
**Codex CLI + OpenAI models** (`--engine codex`). Same plan, same contract,
same loop — see [the engine contract](docs/ENGINES.md).

```
              ./run.sh -n 5
                   │
        ┌──────────▼───────────┐
        │ bash picks the next  │   deterministic — the model never
        │ "- [ ]" from PLAN.md │   chooses what to work on
        └──────────┬───────────┘
        ┌──────────▼───────────┐
        │ agent in Docker      │   writes code · runs tests · ticks the box
        │ (opencode | claude)  │   appends discovered work · opens PR · stops
        └──────────┬───────────┘
        ┌──────────▼───────────┐
        │ GitHub               │   CI → auto-merge → release-please
        └──────────┬───────────┘
                   │  loop waits for the merge, audits the plan delta,
                   ▼  guards against plan bloat, repeats
```

## Install into a project

```bash
cd your-project

# one-liner (public repo)
curl -fsSL https://raw.githubusercontent.com/yildirimarda/agentloop/main/install.sh | bash

# pin a release
curl -fsSL https://raw.githubusercontent.com/yildirimarda/agentloop/main/install.sh \
  | bash -s -- --ref v0.1.0

# private repo / no curl: clone and run (works with your git credentials)
git clone https://github.com/yildirimarda/agentloop.git
agentloop/install.sh /path/to/your-project

# set models while installing
... | bash -s -- --model vendor/model --small-model vendor/cheap-model
```

The installer copies the template, marks what's yours vs what's managed,
appends `.gitignore` entries, records the installed version in `.agentloop`,
and prints the remaining per-project steps (models, `AGENTS.md` project
reference, `ci.yml`, one `docker build` per machine, keychain, `setup-github.sh`).

Full walkthrough with expected output at every step: **[docs/SETUP.md](docs/SETUP.md)**.

## Update a project later

```bash
curl -fsSL .../install.sh | bash -s -- --update --ref v0.2.0
```

Managed files (`run.sh`, `setup-github.sh`, `automerge.yml`) are refreshed in
place. Files you own (`PLAN.md`, `AGENTS.md`, `opencode.json`,
`Dockerfile.agent`, `release.yml`) are never overwritten — if the template
version changed, it lands next to yours as `<file>.agentloop-new` so you can
diff and adopt what you want. An existing `ci.yml` is never touched at all.
The installer also has `--check` (installed vs newest release, changes
nothing), `--uninstall` (removes only agentloop's managed files and stamp;
everything of yours stays), and `--only scripts,workflows,config,plan,claude`
to install a subset into repos that already have parts of the setup.

## What gets installed

Three file classes — **nothing of yours is ever silently overwritten**:

| File | Class | Behaviour when the file already exists |
|---|---|---|
| `run.sh` | managed | Refreshed on `--update` if it's ours (`.agentloop` stamp). A foreign file with the same name is kept; ours lands as `.agentloop-new` with a warning |
| `setup-github.sh` | managed | Same |
| `.github/workflows/automerge.yml` | managed | Same |
| `.github/workflows/release.yml` | yours | Kept once installed — projects legitimately customize `release-type` (e.g. `simple` for tag-derived dynamic versions) |
| `CLAUDE.md` | **merged** | Your content stays; an `@AGENTS.md` import line is appended (once) |
| `.mcp.json` | **merged** | The `graphify` server is added alongside your existing MCP servers |
| `.claude/settings.json` | **merged** | Our deny rules are unioned into yours; your allow/deny/other keys survive |
| `PLAN.md` | yours | Never touched, never even offered a `.agentloop-new` — your plan is authoritative |
| `AGENTS.md` | yours | Kept. If the *template* version changed since your install, the new one lands as `.agentloop-new` to diff |
| `opencode.json` | yours | Same |
| `Dockerfile.agent` | yours | Same |
| `.github/workflows/ci.yml` | ci | Installed only when the project has no CI. An existing pipeline is authoritative: kept untouched, no `.agentloop-new`, nothing to reconcile — `./run.sh --github-setup` auto-detects its check name from the runs on `main` |

All merges are idempotent — running the installer twice adds nothing twice.

## Host-independent by design

Every GitHub interaction — the agent's pushes and PRs, the loop's merge
polling, even one-time repo setup (`./run.sh --github-setup`) — runs **inside
the container**, authenticated by repo-scoped tokens from the macOS keychain.
The host machine needs Docker and git, but no `gh` login and no GitHub
credentials. Handy when you juggle work and personal GitHub accounts on one
machine: the loop can't pick the wrong one, because it never touches either.

## Design in one paragraph

Everything deterministic lives in bash or GitHub; the model only writes code
and notices what else the project needs. Selection is deterministic (bash
greps the first unchecked item), discovery is delegated (the agent may append
up to 3 items per session, append-only, with a growth cap), verification is
repo state (`git log`, PR existence, checkbox delta — never the model's word),
and safety is layered (Docker boundary, permission deny rules, scoped
fine-grained PAT, branch protection — none of which relies on the model
behaving). Graphify gives the agent a knowledge graph of the codebase over
MCP, so it queries relationships instead of reading whole files, which is what
makes free-tier token budgets workable.

## Repository layout

```
install.sh          the installer (local and remote mode)
template/           everything that lands in a target project
docs/SETUP.md       full walkthrough: phases 0-8, troubleshooting, reference
docs/ENGINES.md     the engine contract — what a third engine must satisfy
tests/              installer test suite (runs in CI)
PLAN.md             this repo's own roadmap — agentloop develops itself
version.txt         current version (managed by release-please)
```

Releases are cut by release-please from conventional commits; install with
`--ref vX.Y.Z` to pin one.

## Roadmap

See [PLAN.md](PLAN.md) — next up: stricter shellcheck in CI, which this repo
will fix by running its own loop: `./install.sh . && ./run.sh`.

## License

MIT — see [LICENSE](LICENSE).
