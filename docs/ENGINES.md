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
| Credentials | Environment: `OPENROUTER_API_KEY`, `ANTHROPIC_API_KEY`, `CODEX_API_KEY`, `GH_TOKEN` |
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
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash"},
                                          {"type":"text","text":"…"}]}}
{"type":"result","total_cost_usd":0.42}

// Codex: item envelopes + per-turn usage
{"type":"item.started","item":{"type":"command_execution","command":"bash -lc ls","status":"in_progress"}}
{"type":"item.completed","item":{"type":"agent_message","text":"…"}}
{"type":"item.completed","item":{"type":"reasoning","text":"…"}}
{"type":"turn.completed","usage":{"input_tokens":24763,"output_tokens":122}}
{"type":"turn.failed","error":{"message":"…"}}
```

Adding an engine means extending two jq programs: `stream_view` (live view)
and the tools-used summary in `run_agent`. `tests/install-test.sh` §11 pins
these parsers against recorded fixture lines — add fixtures for the new engine
there, from a real session log.

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
| codex | — (no command-deny mechanism) | approval/sandbox modes only, no per-command globs. The GitHub-side layers carry the weight: the PAT cannot push workflows, branch protection blocks main. Treat codex as the least-guarded engine |
| *(new)* | its own config file | must express the same deny set, or document why the outer layers suffice |

The workflow contract reaches each engine differently: OpenCode and Codex
read `AGENTS.md` natively (Codex: git root down to cwd, concatenated);
Claude Code reads `CLAUDE.md`, which imports it (`@AGENTS.md`). A new engine
needs an equivalent bridge so `AGENTS.md` stays the single source of truth.

## Checklist for adding an engine

1. Install its CLI in `Dockerfile.agent`.
2. Add its invocation branch in `run_agent` (full-autonomy flag, JSON stream,
   model flag passthrough).
3. Extend `stream_view` + the summary jq with its event shapes; add recorded
   fixtures to `tests/install-test.sh` §11.
4. Ship its guardrail config in `template/` and register it in `install.sh`
   (managed or merged class), asserting it in the test suite.
5. Bridge `AGENTS.md` into whatever rules file it reads.
6. Wire its credential: keychain entry → `in_container` env var, fetched only
   when that engine is selected.
7. Document the keychain step in `docs/SETUP.md`.
