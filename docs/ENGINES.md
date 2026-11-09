# Engine contract

An "engine" is the coding agent CLI that `run.sh` drives inside the container.
Three ship today — `opencode` (default), `claude`, and `codex` — and this
document is the contract any further engine must satisfy.

The guiding principle: **run.sh trusts no engine.** The loop's own guarantees —
deterministic item selection, work-branch creation, PR-based verification,
merge-waiting, CI auto-fix — live in bash and apply identically to every
engine. An engine only has to (a) take a prompt, (b) act with full permissions
inside the container, and (c) stream parseable events.

## Inputs

| Input | How it's delivered |
|---|---|
| The prompt | Single argv string (item text wrapped by `prompt_item`, or raw `--task` text) |
| Model override | `-m/--model` flag → forwarded to the engine's own model flag |
| Credentials | Environment: `OPENROUTER_API_KEY`, `NVIDIA_API_KEY`, `ANTHROPIC_API_KEY`, `CODEX_API_KEY`, `GH_TOKEN` |
| Full autonomy | Engine-specific flag/config — the container is the safety boundary, so "never ask" must be on |
| Working dir | `/work` (the repo, bind-mounted; already on a fresh work branch) |

Current invocations (in `run_agent`):

```bash
opencode run --format json [-m MODEL] "$prompt"
claude -p "$prompt" --permission-mode bypassPermissions \
       --output-format stream-json --verbose [--model MODEL]
codex exec --json --dangerously-bypass-approvals-and-sandbox \
      [-c model="MODEL"] "$prompt"
```

Codex note: it ships its own bubblewrap sandbox, which cannot start inside
our container — and doesn't need to, because the container is already the
boundary. Hence the bypass flag (same reasoning as `bypassPermissions` for
Claude Code). Auth is `CODEX_API_KEY` (keychain entry `codex`).

## Output: NDJSON event stream on stdout

The stream is tee'd verbatim to `logs/<ts>-<engine>.jsonl` and piped through
`stream_view` for the terminal. A new engine must emit one JSON object per
line; `stream_view` and the end-of-run summary need to recognise, at minimum:

- **tool calls** — name plus (ideally) the input, so the live view can show
  `→ bash: git status` and the summary can count per-tool usage
- **assistant text** — the model's prose
- **errors**

Reference shapes already handled:

```jsonc
// OpenCode: payload under .part
{"type":"tool_use","part":{"tool":"bash","state":{"input":{"command":"…"}},
  "metadata":{"openrouter":{"reasoning_details":[{"text":"…"}]}}}}
{"type":"text","part":{"text":"…"}}
{"type":"step_finish","part":{"tokens":{"total":10309}}}
{"type":"error","error":{"message":"…"}}

// Claude Code: content blocks inside assistant messages
{"type":"system","subtype":"init","model":"…","mcp_servers":[{"name":"graphify","status":"connected"}]}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"…"}},
                                          {"type":"thinking","thinking":"…"},
                                          {"type":"text","text":"…"}]}}
{"type":"result","total_cost_usd":0.42,"usage":{"input_tokens":…,"output_tokens":…}}
{"type":"result","is_error":true,"result":"…"}

// Codex: item envelopes + per-turn usage
{"type":"item.started","item":{"type":"command_execution","command":"bash -lc ls","status":"in_progress"}}
{"type":"item.completed","item":{"type":"agent_message","text":"…"}}
{"type":"item.completed","item":{"type":"reasoning","text":"…"}}
{"type":"turn.completed","usage":{"input_tokens":24763,"output_tokens":122}}
{"type":"turn.failed","error":{"message":"…"}}
```

Adding an engine means extending the jq programs in `run.sh`: `stream_view`
(live view), and in `run_agent` the tools-used summary plus the session
metrics (tokens, cost, knowledge-graph queries) that feed `logs/history.tsv`,
`--stats` and `--max-cost`. `tests/install-test.sh` §11 pins the parsers
against recorded fixture lines — add fixtures for the new engine there, from a
real session log.

## Providers inside the opencode engine

OpenCode can talk to several model providers; the loop passes the keys for the
ones it knows (keychain entry → env var in the container):

| Provider | Keychain entry | Env var | Model id |
|---|---|---|---|
| OpenRouter | `openrouter` | `OPENROUTER_API_KEY` | `openrouter/vendor/model` |
| NVIDIA NIM | `nvidia` | `NVIDIA_API_KEY` | `nvidia-nim/vendor/model` |

NVIDIA NIM is OpenAI-compatible, so it is declared in `opencode.json` as a
custom provider (the NIM free tier queues third-party models, so a paid or
dedicated endpoint is the realistic use):

```jsonc
"provider": {
  "nvidia-nim": {
    "npm": "@ai-sdk/openai-compatible",
    "name": "NVIDIA NIM",
    "options": {
      "baseURL": "https://integrate.api.nvidia.com/v1",
      "apiKey": "{env:NVIDIA_API_KEY}",
      "timeout": 600000
    },
    "models": {
      "deepseek-ai/deepseek-v4.1-flash": {
        "name": "DeepSeek V4.1 Flash", "tool_call": true, "reasoning": true,
        "limit": { "context": 1000000, "output": 16384 }
      }
    }
  }
}
```

```
security add-generic-password -s nvidia -a "$USER" -w 'nvapi-...'
./run.sh -m nvidia-nim/deepseek-ai/deepseek-v4.1-flash      # or MODEL=... in .agentloop.local
```

When the model id starts with `nvidia`, the OpenRouter key becomes optional.

## Rate limits and small models

`RPM RPD TPM TPD ITPM OTPM` (default 0 = unlimited) make `run.sh` pace a
session: `rate_gate` sits between the engine and the log, turns each completed
model request into a ledger line (`logs/.rate-usage`: epoch, input, output
tokens) and, when one more request of the same size would break a limit,
`docker pause`s the container until enough of the window has passed. An engine
only has to emit a usage-bearing event per request: opencode `step_finish`
(`.part.tokens.input/output`), codex `turn.completed` (`.usage`), claude
`assistant` messages (`.message.usage`, once per `.message.id`). A new engine
extends the jq program in `rate_gate`.

Cached prompt tokens count as input by default (`RATE_CACHE=1`; providers meter
the whole prompt, and a long agent session is mostly cache reads). Engines
report them differently, and `rate_gate` normalises: opencode adds
`tokens.cache.read` + `.write` to `input`, claude adds `cache_read_input_tokens`
+ `cache_creation_input_tokens`, codex's `input_tokens` already contains
`cached_input_tokens` (subtracted when `RATE_CACHE=0`). Turn it off for APIs
where cache reads are free, such as Anthropic's ITPM.

Claude's first event per message can carry a provisional `output_tokens`, so
OTPM / TPM / TPD are conservative-low for that engine (ITPM and the request
limits are exact).

`SMALL_MODEL` reaches the engine by environment so the project files stay
untouched: opencode gets `OPENCODE_CONFIG_CONTENT={"small_model": ...}`, claude
`ANTHROPIC_DEFAULT_HAIKU_MODEL`; codex has no equivalent and ignores it.

## Session limits and failure handling

- `--stall-timeout N` (default 45 min) kills a session that has produced no
  output — a hung API call. The container dies and the loop continues with its
  usual no-PR / no-commits handling. `0` disables it. Persist with
  `STALL_MIN` in `.agentloop.local`. There is deliberately no cap on total
  session length: a healthy session keeps emitting events.
- Ctrl+C (or `kill`) stops every container of the run. Containers carry a
  per-run label (and the repo path), so only this run's containers are stopped
  and other projects are never touched. A container left by a run that died
  uncleanly is cleaned up at the next start; if its run.sh is still alive, the
  new run refuses to start instead.
- On any failure the checkout returns to `main` and the work branch is KEPT;
  the message prints the commands to inspect or delete it. Uncommitted
  leftovers are stashed, never discarded.
- A CI failure is reported only after all other checks finish, with the log of
  every failed job (per platform). Runs GitHub cancels on its own are re-run
  once automatically.

## Exit codes: explicitly NOT part of the contract

Engines exit 0 while having done nothing, and non-zero while having succeeded
(both observed in production). `run.sh` verifies work by asking GitHub whether
a PR exists for the work branch, with local commits as fallback diagnostics.
A new engine gets this for free — don't build anything on its exit code.

## Guardrails are per-engine files

The container blocks filesystem/network escape, but git-history and workflow
protections are engine-config:

| Engine | File | Mechanism |
|---|---|---|
| opencode | `opencode.json` → `permission` | glob deny rules (force push, push to main, terraform apply, workflow edits) |
| claude | `.claude/settings.json` → `permissions.deny` | same rules, Claude Code syntax |
| codex | — (no command-deny mechanism) | approval/sandbox modes only, no per-command globs. The git guard below and the GitHub-side layers (the PAT cannot push workflows, branch protection blocks main) carry the weight |
| *(all)* | `logs/.git-guard`, written by `run.sh` | **git guard**: a `git` wrapper mounted read-only as `/usr/local/sbin/git` (ahead of the real git on PATH) in every container. It refuses force pushes, deletions, pushes to `main`/`master` (from the command line and from a `git push --dry-run --porcelain` of the same command, so config, wildcards and aliases are covered) and pushes whose unpushed commits contain the value of any secret in the container's environment — identically for every engine, and also on private Free-plan repos where branch protection is unavailable. `GIT_GUARD=0` disables it |
| *(new)* | its own config file | must express the same deny set, or document why the outer layers suffice |

The workflow contract reaches each engine differently: OpenCode and Codex
read `AGENTS.md` natively (Codex: git root down to cwd, concatenated);
Claude Code reads `CLAUDE.md`, which imports it (`@AGENTS.md`). A new engine
needs an equivalent bridge so `AGENTS.md` stays the single source of truth.

## Skills reach every engine from one directory

Skills live once, in the portable [Agent Skills](https://agentskills.io)
location `.agents/skills/<name>/SKILL.md`:

| Engine | How it finds them |
|---|---|
| opencode | native: walks `.agents/skills/` (also `.opencode/skills/`, `.claude/skills/`); loads via its `skill` tool |
| codex | native: scans `.agents/skills/` from cwd up to the repo root |
| claude | bridged: `run.sh` mounts `.agents/skills/` read-only at `/home/agent/.claude/skills` (Claude's personal skills dir) for claude sessions only — no duplicate tree in the repo, and opencode never sees the same skills twice |
| *(new)* | must see `.agents/skills/` natively or get an equivalent read-only bridge |

Prompts don't rely on implicit triggering (weaker in headless modes): when a
session needs a specific skill, the prompt names it with its path, which
works in any engine — at worst as a plain file read. `run.sh` only names
skills that are actually installed.

## Checklist for adding an engine

1. Install its CLI in `Dockerfile.agent`.
2. Add its invocation branch in `run_agent` (full-autonomy flag, JSON stream,
   model flag passthrough).
3. Extend `stream_view` + the summary jq with its event shapes; add recorded
   fixtures to `tests/install-test.sh` §11.
4. Ship its guardrail config in `template/` and register it in `install.sh`
   (managed or merged class), asserting it in the test suite.
5. Bridge `AGENTS.md` into whatever rules file it reads, and make
   `.agents/skills/` visible to it (natively or by a read-only mount).
6. Wire its credential: keychain entry → `in_container` env var, fetched only
   when that engine is selected.
7. Document the keychain step in `docs/SETUP.md`.
8. Add a `tests/loop-test.sh` scenario that runs the loop with
   `--engine <new>` (the stub engine answers to any name you symlink to it).
