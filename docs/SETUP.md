# Autonomous development loop

The agent reads `PLAN.md`, takes the next unfinished item, implements it, records
any new work it discovered, opens a pull request, and stops. GitHub merges it.
Then the loop takes the next item.

You write the plan once — or have the agent draft it — then run `./run.sh`.

```
                        ./run.sh -n 5
                             │
        ┌────────────────────▼─────────────────────┐
        │  read PLAN.md, take first "- [ ]" item   │  ← bash, deterministic
        └────────────────────┬─────────────────────┘
                             │
        ┌────────────────────▼─────────────────────┐
        │  AGENT (in container)                    │
        │  query knowledge graph → write code      │
        │  → test → fix → tick the box             │
        │  → append work it discovered             │
        │  → push → open PR → stop                 │
        └────────────────────┬─────────────────────┘
                             │
        ┌────────────────────▼─────────────────────┐
        │  GITHUB — no AI involved                 │
        │  CI → auto-merge → release-please        │
        └────────────────────┬─────────────────────┘
                             │
        ┌────────────────────▼─────────────────────┐
        │  loop waits for merge, reports what the  │  ← bash
        │  agent added, guards against plan bloat  │
        └────────────────────┬─────────────────────┘
                             │
                          repeat
```

**Contents**

- [Who decides what](#who-decides-what)
- [Files](#files)
- **Installation**
  - [Phase 0 — Machine prerequisites](#phase-0--machine-prerequisites)
  - [Phase 1 — CI baseline on main](#phase-1--ci-baseline-on-main)
  - [Phase 2 — The rest of the config, still on main](#phase-2--the-rest-of-the-config-still-on-main)
  - [Phase 3 — Build and verify the container](#phase-3--build-and-verify-the-container)
  - [Phase 4 — Lock down GitHub](#phase-4--lock-down-github)
  - [Phase 5 — Get a plan](#phase-5--get-a-plan)
  - [Phase 6 — One run, watched closely](#phase-6--one-run-watched-closely)
  - [Phase 7 — Let it loop](#phase-7--let-it-loop)
  - [Phase 8 — Ongoing rhythm](#phase-8--ongoing-rhythm)
- **Reference**
  - [Commands and flags](#commands-and-flags)
  - [Optional second engine: paid Claude Code](#optional-second-engine-paid-claude-code)
  - [How the loop stays honest](#how-the-loop-stays-honest)
  - [Graphify: why token usage stays low](#graphify-why-token-usage-stays-low)
  - [Why Docker means less configuration](#why-docker-means-less-configuration)
  - [Division of responsibility](#division-of-responsibility)
  - [Token and context budget](#token-and-context-budget)
  - [How releases work](#how-releases-work)
  - [Notes](#notes)
  - [Every stop message and what to do](#every-stop-message-and-what-to-do)
  - [Quick reference](#quick-reference)
  - [Later: reuse the same image in CI](#later-reuse-the-same-image-in-ci)
  - [References](#references)

---

## Who decides what

The design decision everything else follows from.

| Decision | Made by | Why |
|---|---|---|
| **Which item to work on now** | bash (`run.sh`) | Greps the first `- [ ]` and puts that exact text in the prompt. The agent can't drift onto something else, redo finished work, or skip ahead. |
| **What the project needs** | the agent | It appends discovered work to `PLAN.md` as it goes — up to 3 items per session, append-only. This is where it earns its keep. |
| **Whether work is done** | bash + CI | Verified against `git log`, `gh pr view`, and the checkbox delta. Never the model's word for it. |
| **Whether the plan is sane** | you | `--init` and `--replan` PRs are labelled `plan` and deliberately excluded from auto-merge. |

The agent absolutely decides *what to build* — it just doesn't decide *what to
build right now*. Selection stays deterministic; discovery is delegated.

The reason to split them: picking the wrong item is a silent failure you notice
three PRs later, and unwinding is expensive. A bad discovered item is one line
you delete. The risks are asymmetric, so the two decisions live in different
places.

Two guardrails keep discovery from running away:

- **Append-only.** The agent may tick its own box and add items at the end of a
  milestone or under `## Discovered`. It may not delete, reorder, reword, or
  touch anything above its current item. Only `--replan` may restructure.
- **Growth cap.** `run.sh` computes how many items were added each iteration
  from the done/remaining deltas, prints them, and aborts if the plan grows by
  more than `--max-growth` (default 10) in one run. A plan growing faster than
  it shrinks means the items are too broad or the model is padding — you want to
  know immediately, not after 40 PRs.

---

## Files

```
repo/
├── PLAN.md                        the agent's queue and notebook
├── AGENTS.md                      the workflow contract (both engines)
├── CLAUDE.md                      one-line import of AGENTS.md for Claude Code
├── opencode.json                  OpenCode: permissions, guardrails, Graphify MCP
├── .claude/settings.json          Claude Code: the same deny guardrails
├── .mcp.json                      Claude Code: the same Graphify MCP
├── Dockerfile.agent               the agent's container (both engines inside)
├── run.sh                         the single entry point (--engine picks one)
├── setup-github.sh                one-time GitHub configuration
├── .agentloop                     version stamp written by the installer
└── .github/workflows/
    ├── ci.yml                     lint + tests, the required status check
    ├── automerge.yml              merges green "automated" PRs
    └── release.yml                release-please
```

---

# Installation

Step by step into a real repository. Every step has an expected output and what
to do when it doesn't appear.

Total time: about 90 minutes, roughly half of it waiting on a Docker build and a
CI run. You can stop after any phase and pick up later.

Conventions: `$` lines are what you type, everything else is what you should see.
Version numbers in expected output are illustrative — yours will differ.

---

## Phase 0 — Machine prerequisites

Once per machine, not per project. Skip anything you already have.

### 0.1 Install the tools

```
$ brew install colima docker gh jq
```

What each is for:

| Tool | Why |
|---|---|
| `colima` | Runs the Linux VM that Docker needs on macOS. Lighter than Docker Desktop and no licence questions. |
| `docker` | The CLI only. `colima` provides the engine. |
| `gh` | **Optional.** The loop never uses host gh — every GitHub call (agent pushes, PR polling, even repo setup via `--github-setup`) runs inside the container with a keychain token. Host gh is only a convenience for one-off commands like `gh pr list`. |
| `jq` | `run.sh` uses it to summarise which tools the agent called. Without it you lose that summary but nothing breaks. |

If you already run **Docker Desktop**, skip `colima` entirely — everything else
works unchanged. Just make sure Desktop is running before Phase 3.

### 0.2 Start the VM

```
$ colima start --cpu 4 --memory 8 --disk 60
```

Sizing: 4 CPU / 8 GB is comfortable for a test suite plus a local Spark job. Drop
to `--cpu 2 --memory 4` on a small machine — builds get slower but nothing fails.
`--disk 60` is generous; the image plus caches lands around 4-6 GB.

First start takes a minute or two while it downloads the VM image.

**Verify**

```
$ docker info | head -3
Client: Docker Engine - Community
 Version:    27.x.x
 Context:    colima
```

The `Context: colima` line confirms the CLI is talking to the right engine.

### 0.3 Authenticate gh (optional)

Skip this if you don't want gh on the host — nothing in the loop needs it. If
you do want it for convenience commands:

```
$ gh auth login
```

Answer: **GitHub.com** → **HTTPS** → **Login with a web browser** (or paste a
token if your browser is logged into a different GitHub account).

Note that pushing workflow files with your own `git push` (Phase 1) needs your
personal PAT to include the `workflow` scope.

### 0.4 OpenRouter account and credit

1. Sign up at `openrouter.ai`.
2. **Add $10 of credit.** This is not optional for this setup. Accounts under $10
   are capped at **50 free-model requests per day**; at $10 or more the cap
   becomes **1,000/day**, permanently. One agent task costs roughly 20-60
   requests, so 50/day means about one task per day. You don't spend the $10 —
   free models stay free. You're buying the higher ceiling.
3. Create an API key at `openrouter.ai/settings/keys`. It starts with
   `sk-or-v1-`.

The 20 requests/minute ceiling applies regardless of credit. That's fine here
because the loop is serial by design.

### 0.5 Store the key in the macOS keychain

Don't put it in `.zshrc` — that file ends up in dotfile repos and pasted gists.

```
$ security add-generic-password -s openrouter -a "$USER" -w 'sk-or-v1-...'
```

**Verify**

```
$ security find-generic-password -s openrouter -w | head -c 12
sk-or-v1-abc
```

### Phase 0 troubleshooting

| Symptom | Cause and fix |
|---|---|
| `colima start` fails on disk | Not enough free space. Retry with `--disk 30`. |
| `docker info` says `Cannot connect to the Docker daemon` | VM isn't up. `colima status`, then `colima start`. |
| `docker info` shows `Context: default` with Desktop not running | `docker context use colima` |
| `gh auth status` shows no `workflow` scope | `gh auth refresh -s workflow` |
| `security: SecKeychainSearch... not found` | The entry name must match exactly: `-s openrouter`. |

---

## Phase 1 — CI baseline on main

**Project already has CI?** Then this phase is just: confirm the *latest
existing* run on `main` is green (Actions tab — this predates agentloop, since
you haven't pushed anything yet). The installer never touches an existing
`ci.yml` (it's authoritative), and `--github-setup` auto-detects your
pipeline's check name from the runs on main — no renaming, no merging. If main
is red, fix that first; then skip straight to Phase 2 and run the installer
there (the install command below is repeated at 2.1).

For projects without CI: install **only** `ci.yml` first and get it green
before anything else touches this repo.

### 1.1 Install the files, commit only ci.yml

**Starting a brand-new project?** Create the repo first — everything below
assumes a repo with a `main` branch on GitHub:

```
$ gh repo create my-project --private --clone && cd my-project
$ git commit --allow-empty -m "chore: init" && git push -u origin main
```

Then install agentloop (this copies ALL the files at once — the phasing below
is about what you *commit* first, not what you copy):

```
$ cd /path/to/your/repo
$ curl -fsSL https://raw.githubusercontent.com/yildirimarda/agentloop/main/install.sh | bash
    # or, from a local clone (works for private repos):
$ /path/to/agentloop/install.sh .
    # pin a release:  ... | bash -s -- --ref v0.1.0
```

Stage and push **only** `ci.yml` for now — you want a green CI baseline before
anything else lands:

### 1.2 Make it match your project

Open `.github/workflows/ci.yml`. The template assumes Python with `uv`, `ruff`
and `pytest`. **The job must stay named `ci`** — Phase 4 registers that exact
string as the required status check. Everything else is yours to change.

**If you use uv + ruff + pytest**, no changes needed.

**If you use Poetry:**

```yaml
      - uses: actions/setup-python@v5
        with:
          python-version: '3.12'
      - run: pipx install poetry
      - run: poetry install --with dev
      - run: poetry run ruff check .
      - run: poetry run pytest -q
```

**If you use npm:**

```yaml
      - uses: actions/setup-node@v4
        with:
          node-version: '22'
          cache: npm
      - run: npm ci
      - run: npm run lint
      - run: npm test
```

Delete the steps you don't need. The Terraform block is already conditional — it
only runs if the repo contains `.tf` files, so you can leave it. If you need Java
or Spark in CI, uncomment the `setup-java` step at the bottom.

### 1.3 Push it

```
$ git add .github/workflows/ci.yml
$ git commit -m "ci: add lint and test workflow"
$ git push
$ gh run watch
```

`gh run watch` follows the run live:

```
✓ main ci · 12345678901
Triggered via push about 10 seconds ago

JOBS
✓ ci in 47s (ID 98765432101)
  ✓ Set up job
  ✓ Run actions/checkout@v4
  ✓ Install dependencies
  ✓ Lint
  ✓ Tests
  ✓ Complete job

✓ Run ci (12345678901) completed with 'success'
```

**Verify:** the last line says `completed with 'success'`.

**Brand-new empty repo?** The python steps detect that there's no
`pyproject.toml` yet and skip themselves, so the job is green by design. Real
checks kick in automatically once the `--init` PR lands the scaffolding.

### 1.4 Why this phase exists

If your existing code doesn't pass its own lint and tests, you need to know
**now**, before an agent is involved. Otherwise every agent PR comes back red and
you cannot tell whether the agent broke something or the repo was already broken.
That's the single most annoying state to debug in this whole setup, and it's
entirely avoidable by spending twenty minutes here.

### Phase 1 troubleshooting

| Symptom | Fix |
|---|---|
| Lint fails on hundreds of legacy files | Either fix them now (`ruff check --fix .` then commit) or delete the lint step for now and add it back later. Do not leave CI red. |
| `ruff format --check` fails everywhere | Run `ruff format .`, commit the churn as `style: apply formatter`, then CI passes. |
| Tests fail | Fix them, mark genuinely broken ones `@pytest.mark.skip` **with a reason**, or narrow the test path. Note: `AGENTS.md` forbids the *agent* from skipping tests. You're allowed to, once, to establish a baseline. |
| `uv sync` fails: no lockfile | `uv lock` locally, commit `uv.lock`. |
| `refusing to allow an OAuth App to create or update workflow` | Missing `workflow` scope: `gh auth refresh -s workflow` |
| Nothing triggers | Check the `on:` block matches your branch name (`main` vs `master`). |

---

## Phase 2 — The rest of the config, still on main

### 2.1 Commit the rest

**Skipped Phase 1's install because you already have CI?** Run the installer
now — same command:

```
$ curl -fsSL https://raw.githubusercontent.com/yildirimarda/agentloop/main/install.sh | bash
```

**Already had some of these files?** The installer never clobbers: an existing
`CLAUDE.md` gets an appended `@AGENTS.md` import (your content stays),
`.mcp.json` gains the graphify server next to your servers,
`.claude/settings.json` gets our deny rules unioned into yours, and an existing
`PLAN.md`/`AGENTS.md` is kept as-is. Any real name collision (say you already
had a `run.sh`) keeps your file and saves ours as `<file>.agentloop-new` with a
warning — diff and merge those before continuing.

The installer already copied everything, made the scripts executable, appended
`.gitignore` entries (`logs/` for run transcripts, `graphify-out/` for the
regenerated knowledge graph, `.opencode/` for session state, `*.agentloop-new`
for update artifacts) and wrote a `.agentloop` version stamp. Nothing left to
copy — just commit it after the two edits below (2.2 and 2.3).

**Why straight to `main` rather than a PR:** `automerge.yml` isn't live yet and
the `automated` label doesn't exist yet, so a PR would just be you reviewing
yourself and merging by hand. These are infrastructure files, not features.

### 2.2 Choose a model

1. Go to `openrouter.ai/collections/tool-calling-models`. This filter matters —
   **a model without tool calling is completely useless here.** It can't run your
   tests, can't use git, can't query the graph.
2. Narrow to free models.
3. Note the model ID. It looks like `vendor/model-name`. In `opencode.json` you
   prefix it with the provider: `openrouter/vendor/model-name`.

Open `opencode.json` and replace both placeholders:

```json
  "model": "openrouter/vendor/some-capable-model",
  "small_model": "openrouter/vendor/some-cheap-model",
```

`small_model` only handles titles and summaries — put the cheapest thing there.

**Optional but recommended:** confirm the model responds at all before you build
a container around it.

```
$ curl -s https://openrouter.ai/api/v1/chat/completions \
  -H "Authorization: Bearer $(security find-generic-password -s openrouter -w)" \
  -H "Content-Type: application/json" \
  -d '{"model":"vendor/some-capable-model","messages":[{"role":"user","content":"say ok"}]}' \
  | jq -r '.choices[0].message.content // .error.message'
ok
```

If you get an error message instead of `ok`, the model ID is wrong or that model
isn't available to you. Fix it now — much easier to debug here than through two
layers of container.

### 2.3 Fill in the project reference

Open `AGENTS.md`, scroll to **Project reference** at the bottom, and put in your
real commands. This is the single most impactful edit in the file: if these are
wrong, the agent runs the wrong command every session and burns turns finding
out.

A filled-in example:

```markdown
## Project reference

- Tests:        `uv run pytest -q`
- Lint:         `uv run ruff check .`
- Format:       `uv run ruff format .`
- Dependencies: `uv sync` / `uv add <package>`
- Source:       `src/billing_loader/`
- Tests dir:    `tests/`
- Entry point:  `uv run billing-loader --help`
- Migrations:   `uv run alembic upgrade head`
- Local DB:     `docker compose up -d postgres` (port 5433)
```

Add anything project-specific the agent would otherwise have to guess. Keep it
short — this text goes into every single prompt.

### 2.4 One web setting, THEN commit

The files you're about to push include `release.yml`, which runs on every push
to `main` and opens pull requests. GitHub blocks that by default, so its very
first run fails with *"GitHub Actions is not permitted to create or approve
pull requests"* unless you flip this setting first:

Repo → **Settings → Actions → General → Workflow permissions**:

- Select **Read and write permissions**
- Check **Allow GitHub Actions to create and approve pull requests**
- Save

(`automerge.yml` needs the same setting — one visit covers both.)

Now commit and push:

```
$ git add -A
$ git commit -m "chore: add autonomous agent setup"
$ git push
```

**Verify**

```
$ python3 -c "import json;json.load(open('opencode.json'))" && echo json-ok
json-ok
$ grep -c CHANGE_ME opencode.json
0
$ ls run.sh setup-github.sh PLAN.md AGENTS.md Dockerfile.agent
AGENTS.md         Dockerfile.agent  PLAN.md           run.sh            setup-github.sh
$ test -x run.sh && echo executable
executable
```

`grep -c CHANGE_ME` must print `0`. If it prints `2`, you skipped 2.2.

### Phase 2 troubleshooting

| Symptom | Fix |
|---|---|
| `json.load` raises | Trailing comma or smart quotes in `opencode.json`. The error names the line. |
| `curl` returns `No endpoints found` | Model ID wrong, or that model has no free endpoint any more. Free listings churn; pick another. |
| `curl` returns `No auth credentials found` | Keychain entry missing or misnamed. Re-check 0.5. |
| `./run.sh: Permission denied` | You skipped `chmod +x`. |

---

## Phase 3 — Build and verify the container

### 3.1 Build

```
$ docker build -t agent -f Dockerfile.agent .
```

First build: 3-8 minutes depending on your connection. Later builds are mostly
cached unless you edit an early layer.

You should end with:

```
 => exporting to image
 => => naming to docker.io/library/agent
```

### 3.2 Smoke-test the tools

```
$ docker run --rm agent bash -lc '
  git --version && gh --version && uv --version &&
  terraform version && java -version && opencode --version &&
  claude --version && graphify --help >/dev/null && echo GRAPHIFY-OK'
```

Expected shape:

```
git version 2.43.0
gh version 2.x.x (2026-xx-xx)
uv 0.x.x
Terraform v1.9.8
on linux_arm64
openjdk version "17.0.x"
OpenJDK Runtime Environment ...
1.x.x
GRAPHIFY-OK
```

**Verify:** it reaches `GRAPHIFY-OK`. If it stops earlier, the last line printed
tells you which tool is missing.

### 3.3 Test indexing on your actual repo

Worth doing separately, because this is the one component with a known rough
edge.

```
$ docker run --rm -v "$PWD:/work" agent \
    graphify extract . --code-only --no-cluster --force
$ ls -lh graphify-out/graph.json
-rw-r--r--  1 you  staff   842K  ... graphify-out/graph.json
```

**Verify:** `graph.json` exists and isn't a few bytes.

**If it fails:** there was a bug where `extract` demanded an LLM API key before
noticing the corpus was code-only. `--code-only` is the documented fix and
`run.sh` passes it, but if you still hit it, just run everything with
`--no-graph`. The loop works fine without the graph — you only lose the token
savings. Don't let this block you.

### 3.4 Add your own tools

Anything you install in the container, the agent can use for local testing. That
is the entire point of the container. Open `Dockerfile.agent`, find:

```dockerfile
# ── ADD YOUR OWN TOOLS HERE ──
```

and add what your project needs:

```dockerfile
RUN apt-get update && apt-get install -y --no-install-recommends \
      postgresql-client redis-tools && rm -rf /var/lib/apt/lists/*
RUN uv tool install pre-commit
RUN npm install -g @redocly/cli
```

Then rebuild (`docker build -t agent -f Dockerfile.agent .`) and re-run 3.2.

Note on pyspark: don't install it here. Keep it in `pyproject.toml` so the agent
installs it with `uv sync` and versions can't drift. Java is already present, so
`spark-submit --master local[2]` works.

### Phase 3 troubleshooting

| Symptom | Fix |
|---|---|
| `terraform: cannot execute binary file` | Architecture mismatch. The Dockerfile detects arch with `dpkg --print-architecture`, so this usually means a stale cached layer: `docker build --no-cache ...` |
| `npm install -g opencode-ai` fails on engine version | Node is too old. The Dockerfile pins NodeSource 22; if you edited that, put it back. |
| apt `404 Not Found` mid-build | Stale package index in a cached layer. `docker build --no-cache ...` |
| Build gets killed | VM out of memory. `colima stop && colima start --memory 8` |
| `graphify: command not found` | The `uv venv /opt/graphify` step failed earlier in the build. Scroll up in the build log. |
| Indexing takes many minutes | Normal on a large monorepo, first time only. Later runs are incremental via per-file SHA256. |

---

## Phase 4 — Lock down GitHub

This is your last line of defence if the agent misbehaves. Do it after Phase 2,
not before, so you're not fighting your own branch protection while pushing
config.

Two ways to run it. **Container route (no host gh login needed):** create a
fine-grained admin token — Repository access: your agentloop repos (reusable
across projects, or create-and-delete per setup since it's needed for thirty
seconds), Permissions: **Administration: Read and write** + **Issues: Read and
write** + **Actions: Read-only** (check-name auto-detection) — store it and
run:

```
$ security add-generic-password -s gh-admin -a "$USER" -w 'github_pat_...'
$ ./run.sh --github-setup
```

**Host route:** if you keep a gh login (Phase 0.3), just run the script
directly, as below. Either way the effect is identical.

### 4.1 Run the script

```
$ ./setup-github.sh
repo:            youruser/yourrepo
required check:  ci

This will lock down main and enable auto-merge. Continue? [y/N] y

> branch protection (main)
  OK  main protected: force push off, CI required

> repository settings
  OK  auto-merge + squash + delete branch on merge

> labels
  OK  automated, blocked, plan
```

What it did:

- **Branch protection on `main`:** `ci` required, must be up to date with main,
  force pushes off, deletions off, zero required reviews.
- **Repository settings:** auto-merge on, squash merge on, delete branch after
  merge.
- **Three labels:** `automated` (auto-merge when green), `blocked` (agent got
  stuck), `plan` (plan change, review it yourself).

Zero required reviews sounds alarming but it's the point: CI is the gate, not a
human. If you'd rather approve each PR, set
`required_pull_request_reviews[required_approving_review_count]=1` — but then the
loop stalls on every item waiting for you, which defeats the purpose.

### 4.2 Create the agent's token

**One token serves every agentloop project.** Fine-grained PATs can be scoped
to a *list* of repositories, so on each new project you don't create a new
token — you open the existing one (github.com/settings/personal-access-tokens
→ Repository access) and add the repo to its list. The keychain entry stays
untouched. Only do the steps below the very first time.

Go to **github.com/settings/personal-access-tokens/new** and set:

| Field | Value |
|---|---|
| Token name | `agent-yourrepo` |
| Expiration | 90 days (set a calendar reminder) |
| Repository access | **Only select repositories** → pick this one repo |
| Permissions → Contents | **Read and write** |
| Permissions → Pull requests | **Read and write** |
| Permissions → Actions | **Read-only** — lets the loop's PR polling read the CI verdict via workflow runs. (You won't find a "Checks" permission: GitHub doesn't offer it on fine-grained PATs, which is why the loop reads the Actions API instead.) |
| Everything else | leave alone |

Do **not** grant: Administration, Actions, Workflows, Secrets, or any
organisation permission.

**Why not just reuse your own token:** if this one leaks, the blast radius is one
repository. And even with the token, the agent cannot rewrite history (force push
is blocked at the repo level) or weaken CI (no Workflows permission, plus
`opencode.json` denies edits to `.github/workflows/**`). Three independent
layers, none of which relies on the model behaving.

Store it:

```
$ security add-generic-password -s gh-agent -a "$USER" -w 'github_pat_...'
```

### 4.3 Let Actions open and merge PRs

You already did this in Phase 2.4 — this step is just the double-check,
because forgetting it is the most confusing failure in the setup (PRs sit
green and unmerged with no error anywhere).

Repo → **Settings** → **Actions** → **General** → scroll to **Workflow
permissions**:

- Select **Read and write permissions**
- Check **Allow GitHub Actions to create and approve pull requests**
- Click **Save**

Skip this and `automerge.yml` silently does nothing. Every PR just sits there
green and unmerged, with no error anywhere — a genuinely confusing failure.

### 4.4 Verify

These verification commands use host gh for convenience — if you don't keep a
host gh login, check the same things in the repo's Settings → Branches and
Settings → General pages instead.

```
$ gh api repos/:owner/:repo/branches/main/protection \
    -q '{checks:.required_status_checks.contexts, force:.allow_force_pushes.enabled, strict:.required_status_checks.strict}'
{
  "checks": [
    "ci"
  ],
  "force": false,
  "strict": true
}

$ gh repo view --json autoMergeAllowed,deleteBranchOnMerge
{"autoMergeAllowed":true,"deleteBranchOnMerge":true}

$ gh label list | grep -E '^(automated|blocked|plan)'
automated  Opened by the agent, auto-merge when green
blocked    Agent is stuck, needs a human
plan       Change to PLAN.md, review before merging

$ security find-generic-password -s gh-agent -w >/dev/null && echo token-ok
token-ok
```

Note: with `enforce_admins=false` **you** can still push to `main`. That's
deliberate — you keep an escape hatch. The agent can't, because its token is
scoped and `opencode.json` denies `git push*main*`.

### Phase 4 troubleshooting

| Symptom | Fix |
|---|---|
| `HTTP 403: Resource not accessible` | You lack admin on the repo, or you're on a free plan with a private repo (branch protection needs Pro or a public repo). |
| `HTTP 422: Invalid request` on protection | Usually a `null` field. The script sends `"restrictions": null` deliberately — don't remove it. |
| Protection applied but PRs merge instantly | The required check name doesn't match what actually runs. The script auto-detects from main's check runs and refuses ambiguous cases, so this should be rare — re-run `./run.sh --github-setup` after CI has run at least once on main, or pin it: `CHECK=<name> ./run.sh --github-setup` |
| PRs never merge, no error | Almost always 4.3 wasn't done. Check it again. |
| `gh label create` says already exists | Harmless, the script passes `--force`. |
| Org blocks fine-grained tokens | Ask an owner to enable them in org settings, or fall back to a classic token with only `repo` — less safe, still workable. |

---

## Phase 5 — Get a plan

### 5.1 New project

```
$ ./run.sh --init "A CLI that ingests CSV exports from our billing system,
validates them against a declared schema, and loads them into Postgres.
Python 3.12, uv, pytest, SQLAlchemy. Must handle files up to 2 GB by
streaming — never read a whole file into memory. Needs a --dry-run mode that
validates without writing. Errors must report the offending row number.
Runs as a nightly cron job in Kubernetes, so it must exit non-zero on any
validation failure and log in JSON."
```

**Be specific about constraints, not just features.** "Streaming, never read a
whole file into memory" shapes a dozen downstream items. "Exit non-zero, JSON
logs" produces two items you'd otherwise have to add yourself later.

Compare:

| Weak | Strong |
|---|---|
| "A CSV loader for Postgres" | The paragraph above |
| "Add auth" | "JWT auth with refresh tokens, 15-minute access token expiry, tokens revocable via a denylist in Redis" |

Longer descriptions are fine. If it runs past a paragraph, put it in a file:

```
$ ./run.sh --init -f brief.md
```

### 5.2 Existing project

Either write `PLAN.md` by hand — the template in the file shows the exact format
— or have the agent read the code and draft one:

```
$ ./run.sh --replan
```

**Already have a roadmap in another format** — status tables, prose, bare `[x]`
lines? The loop can only parse `- [ ]` checkbox lines; anything else is
invisible to it (`./run.sh --next` will tell you when that's the case).
`--replan` is also the converter: it rewrites the existing plan into the
canonical format, preserving every item and its done/not-done status, via a
`plan`-labelled PR you review before merging.

### 5.3 What you'll see

```
────────────────────────────────────────────────────────
MODE: init — drafting PLAN.md
────────────────────────────────────────────────────────
> syncing knowledge graph
  graph built
  log: logs/20260822-141530.jsonl

[... streaming JSON events ...]

  tools used:
     14     bash
      9     write
      4     read
      2     graphify_query_graph

PLAN.md drafted in PR #1.

Review it and merge it yourself:  gh pr view 1 --web
The plan is the one thing worth your review — a bad plan becomes
twenty bad pull requests, and by then it is expensive to undo.
```

### 5.4 Review it

```
$ gh pr view --web
```

**This is the highest-leverage half hour in the whole setup.** Go through the
plan against this checklist:

- **One PR per item?** Anything with "and" in it probably isn't. "Add config
  loading and validation and error messages" is three items.
- **Testable?** "Improve performance" isn't an item. "Add a benchmark that
  asserts 10k rows load in under 2 seconds" is.
- **Ordered correctly?** Item 7 must not depend on item 12. Read it as a sequence
  and check each one is possible when it comes up.
- **Right size overall?** 8-20 items for a first working version. 40 items means
  it planned the whole product; cut the later milestones — the agent will
  rediscover that work as it goes, which is what discovery is for.
- **Anything the agent couldn't know?** Auth model, data retention rules,
  deployment target, an internal API it has to call. Add those yourself.

Edit the file directly in the PR if you want, then merge:

```
$ gh pr merge 1 --squash
```

**Why this matters more than it looks:** a bad plan doesn't fail loudly. It
produces twenty plausible PRs that all pass CI and merge cleanly and add up to
the wrong system. There's no red X to warn you. Reviewing here is much cheaper
than unwinding there.

`automerge.yml` excludes the `plan` label specifically so this PR waits for you.

### Phase 5 troubleshooting

| Symptom | Fix |
|---|---|
| Plan is vague ("Set up backend") | Your description was too thin. Close the PR, delete the branch and the local `PLAN.md`, re-run `--init` with constraints and specifics. (`--init` refuses to overwrite an existing `PLAN.md`, so the delete is deliberate.) |
| Plan has 60 items | Add "plan only the first working version, 8-15 items" to the description and re-run. |
| It implemented features instead of just planning | Weak instruction-following. Note it — the same model will likely ignore other rules too. Consider switching. |
| No PR opened | Check gh auth inside the container: `docker run --rm -e GH_TOKEN=$(security find-generic-password -s gh-agent -w) agent gh auth status` |
| `PLAN.md` format is off | `./run.sh --next` tells you immediately. Fix by hand — checkbox lines must be exactly `- [ ] text`. |

---

## Phase 6 — One run, watched closely

### 6.1 Dry run first

```
$ ./run.sh --next
done:      0
remaining: 12
next:      Set up the project layout, dependency manifest and a placeholder test so the test command passes
```

Free, no API calls. Confirms `PLAN.md` parses and shows what's next.

If `remaining: 0` but the file clearly has items, your checkbox lines are
malformed. They must be exactly `- [ ] ` — hyphen, space, bracket, space,
bracket.

### 6.2 One real item

```
$ ./run.sh
```

Annotated output:

```
────────────────────────────────────────────────────────
TASK 1/1   ·   12 remaining
Set up the project layout, dependency manifest and a placeholder test so the test command passes
────────────────────────────────────────────────────────
> syncing knowledge graph                  ← incremental, seconds
  graph updated
  log: logs/20260822-142011.jsonl

[... streaming events: reads, writes, bash calls ...]

  tools used:                              ← THE IMPORTANT PART
     22     bash
     11     edit
      6     read
      5     graphify_query_graph
      1     graphify_god_nodes

  PR #2 opened
> waiting for PR #2 to merge (timeout 20m)  ← bash polling, no tokens
  merged

────────────────────────────────────────────────────────
completed:     1 item(s)
added to plan: 0 item(s)
plan:          1 done, 11 remaining
next:          Add configuration loading from environment variables, with validation
```

### 6.3 Read the tool list

Two things must be present:

**`bash` calls.** This means the agent actually ran your tests and lint. If there
are none, it wrote code and declared victory without verifying anything — the
most dangerous failure mode, because the PR looks fine and CI is the only thing
catching it. Change the model.

**`graphify_*` calls.** This means the agent queried the knowledge graph instead
of reading files wholesale. If there are none, the MCP server is connected but
your model is ignoring it, so you get none of the token savings. Also a reason to
change the model.

A healthy ratio has `bash` highest (tests, lint, git) and a handful of
`graphify_*` calls. Lots of `read` and no `graphify_*` means it's reading files
the expensive way.

### 6.4 Read the PR before moving on

```
$ gh pr view 2 --web
```

Check: does the diff do only what the item said? Is there a test? Is the
`PLAN.md` checkbox flipped? Does the description explain anything it added to the
plan?

### 6.5 Verify the state

```
$ git switch main && git pull
$ grep -m3 -E '^- \[' PLAN.md
- [x] Set up the project layout, dependency manifest and a placeholder test so the test command passes
- [ ] Add configuration loading from environment variables, with validation
- [ ] Add structured logging with a configurable level
```

The first item is `[x]`. The loop is working end to end.

Anything that stops the run is covered in
[Every stop message and what to do](#every-stop-message-and-what-to-do).

---

## Phase 7 — Let it loop

### 7.1 Three at a time first

```
$ ./run.sh -n 3
```

Read all three PRs. In particular, watch what the agent **added** to the plan —
`run.sh` prints it after each iteration:

```
  the agent added to the plan:
    + Add retry with backoff to the Postgres connection
    + Handle CSV files with a UTF-8 BOM in the header row
```

**How to judge additions:**

| Good | Bad |
|---|---|
| Specific, falls out of the work just done | Vague: "improve error handling" |
| Something you'd have written yourself later | Speculative: "consider adding caching" |
| One clear PR | Restates an existing item in different words |

If you're getting bad ones, run with `--no-discover` for a while and rely on
`--replan` instead. If you're getting good ones, this is the feature earning its
keep — that's work you didn't have to think of.

### 7.2 Then let it run

```
$ ./run.sh -n all
```

It stops when the plan is complete, when CI fails, when a PR won't merge, or when
the plan grows past `--max-growth`.

Useful variants:

```
$ ./run.sh -n all --max-growth 20     # young project, expect more discovery
$ ./run.sh -n 5 --no-discover         # strict: consume the plan, add nothing
$ ./run.sh -n 5 -m openrouter/x/y     # try another model for one run
$ ./run.sh -n 5 --timeout 40          # slow CI
```

### 7.3 Expect to stop sometimes

Stopping is the design working, not a bug. A loop that never stops is a loop that
merges bad code. The three common stops:

- **CI failed** → fix on the same branch with `--task`, the PR updates itself
- **Plan grew past the cap** → `--replan` to prune
- **Item wasn't ticked** → the model ignored `AGENTS.md`; tick it yourself and
  watch whether it recurs

### Phase 7 troubleshooting

| Symptom | Fix |
|---|---|
| Every item stops on CI failure | Your CI is stricter than the commands in `AGENTS.md`. Make them match exactly — if CI runs `ruff format --check`, `AGENTS.md` must tell the agent to run `ruff format`. |
| Timeouts waiting for merge | CI slower than 20 min, or auto-merge isn't enabled. Check 4.3, then raise `--timeout`. |
| Items done in the wrong order | The plan's order is wrong; `run.sh` follows the file literally. `--replan` or edit by hand. |
| Same item attempted twice | The checkbox didn't merge to `main`. Are you running `--no-wait`? Don't, unless you understand this. |
| Rate limit errors | Two copies of `run.sh` running at once. Don't — 20 req/min is shared. |

---

## Phase 8 — Ongoing rhythm

### After each batch

```
$ gh pr list --label blocked                  # needs you
$ gh pr list --state merged --limit 20        # what shipped
$ ./run.sh --next                             # where the plan stands
```

`blocked` PRs are the agent telling you it hit something it couldn't resolve in
three attempts. The description says what it tried. Usually the item was
underspecified — rewrite it in `PLAN.md` and let it try again.

### Weekly

```
$ git log -p --follow -- PLAN.md | head -100   # how the plan drifted
$ ./run.sh --replan                             # promote, split, prune
```

`--replan` is the only mode allowed to restructure `PLAN.md`. Run it when
`## Discovered` has piled up, when items have gone stale, or when the growth cap
tripped. It opens a `plan`-labelled PR — review that one too.

### After large refactors

```
$ ./run.sh --reindex
```

Incremental updates handle normal work, but a big move or rename leaves stale
nodes in the graph.

### Every 90 days

The agent's fine-grained token expires. Regenerate it (4.2) and update the
keychain entry. Symptom if you forget: the agent's `git push` fails with `403`.

### What to watch over time

| Signal | Healthy | Worrying |
|---|---|---|
| Items per successful run | most of what you asked for | frequent stops |
| CI pass rate on first try | above ~70% | below half — `AGENTS.md` commands probably don't match CI |
| Plan growth per item | 0-1 | consistently 3 — items are too broad |
| `graphify_*` calls per run | several | zero — you're paying full token price |
| `blocked` PRs | occasional | frequent — items are underspecified |

---

# Reference

## Commands and flags

| Command | What it does |
|---|---|
| `./run.sh` | Next unchecked item in `PLAN.md` |
| `./run.sh -n 5` | Next 5 items, then stop |
| `./run.sh -n all` | Until the plan is complete |
| `./run.sh --init "desc"` | Draft `PLAN.md` + scaffolding for a new project |
| `./run.sh --init -f brief.md` | Same, description read from a file |
| `./run.sh --replan` | Audit code against `PLAN.md` and restructure it |
| `./run.sh --task "text"` | One-off task, ignores `PLAN.md` |
| `./run.sh --next` | Dry run: print the next item. No API calls |
| `./run.sh --reindex` | Rebuild the Graphify graph from scratch |
| `./run.sh --github-setup` | Branch protection + auto-merge + labels, from inside the container (`gh-admin` keychain token) |
| `./run.sh --help` | All flags |

| Flag | Default | Use when |
|---|---|---|
| `-e, --engine NAME` | `opencode` | `claude` runs the same loop on paid Claude Code — see the next section |
| `--no-discover` | off | You want the plan consumed, not extended |
| `--max-growth N` | 10 | Young project: raise it. Tight scope: lower it |
| `--ci-retries N` | 1 | On a red PR, feed the failing CI log back to the agent on the same branch, up to N times (0 = off) |
| `--auto-replan` | off | When the plan runs out mid-loop, run one replan session (plan PR for your review) instead of just stopping |
| `--ambitious` | off | With `--replan`: adds a vision pass — the agent proposes 5-10 genuinely new product features under a "Proposed Features (vision)" milestone, for you to prune in the plan PR |
| `--headroom` | off | (opencode engine) route the session through an in-container Headroom proxy that compresses old tool outputs before they reach the model. Persist with `HEADROOM=1` in `.agentloop.local` |
| `--no-wait` | off | Rarely — `main` goes stale and items can repeat |
| `--timeout N` | 20 | CI takes longer than 20 minutes |
| `-m ID` | from config | Trying a different model for one run |
| `--no-graph` | off | Graphify is misbehaving |
| `--image NAME` | `agent` | You keep multiple container variants |

**Per-machine defaults without touching git:** put `KEY=VALUE` lines in
`.agentloop.local` (gitignored, created by you). Supported keys: `MODEL`,
`ENGINE`, `CI_RETRIES`, `TIMEOUT_MIN`, `MAX_GROWTH`, `IMAGE`, `AUTO_REPLAN`.
Precedence: CLI flags > `.agentloop.local` > committed defaults
(`opencode.json`). This is the intended way to switch models freely — the
committed config stays the team/repo default; your experiments never require
a commit or push.

---

## Optional second engine: paid Claude Code

The loop is engine-agnostic: `run.sh` picks the plan item, builds the prompt,
verifies the result and waits for the merge regardless of which CLI does the
work in the middle. `--engine claude` swaps OpenCode for Claude Code with
Anthropic models. Everything else — `PLAN.md`, the workflow contract, the
container, branch protection, auto-merge — is shared.

### One-time setup

1. Get an Anthropic API key from `console.anthropic.com` (API billing, not a
   Pro/Max subscription — headless containers authenticate with
   `ANTHROPIC_API_KEY`).
2. Store it:

```
$ security add-generic-password -s anthropic -a "$USER" -w 'sk-ant-...'
```

3. Rebuild the image if you built it before this section existed
   (`docker build -t agent -f Dockerfile.agent .`) and check:

```
$ docker run --rm agent claude --version
```

That's all — the repo files are already in place:

- **`CLAUDE.md`** imports `AGENTS.md`, so both engines follow the identical
  contract. Edit `AGENTS.md` only; never maintain two copies.
- **`.claude/settings.json`** mirrors the `opencode.json` deny rules (no force
  push, no push to main, no terraform apply, no workflow edits). Deny rules
  apply even in `bypassPermissions` mode.
- **`.mcp.json`** wires the same Graphify server, so graph queries work in both
  engines (tool names appear as `mcp__graphify__query_graph` there).

### Usage

```
$ ./run.sh --engine claude --init "..."       # plan with the strong model
$ ./run.sh -n 5                               # routine items on the free engine
$ ./run.sh --engine claude --task "..."       # a hard bug the free model failed
$ ./run.sh --engine claude -n 3               # three plan items on Claude
$ ENGINE=claude ./run.sh --replan             # env var works too
```

`-m` passes through to `claude --model` if you want to pin a specific model;
otherwise Claude Code's default is used.

### Optional third engine: Codex CLI

`--engine codex` runs OpenAI's Codex CLI headlessly (`codex exec --json`)
under the exact same loop. Setup is one keychain entry plus an image rebuild:

```
$ security add-generic-password -s codex -a "$USER" -w '<openai-api-key>'
$ docker build -t agent -f Dockerfile.agent .
$ docker run --rm agent codex --version
```

Two things to know. First, Codex ships its own sandbox (bubblewrap), which
cannot start inside our container — run.sh passes
`--dangerously-bypass-approvals-and-sandbox`, which is safe here for the same
reason `bypassPermissions` is for Claude Code: the container is the boundary.
Second, Codex has **no per-command deny rules** (only coarse approval/sandbox
modes), so it is the least-guarded engine — the GitHub-side layers (PAT
without workflow permissions, branch protection) do the real enforcement.
Codex reads `AGENTS.md` natively, so the workflow contract applies unchanged.
`-m` maps to Codex's `model` config key.

### The split that gets the most per dollar

Use the paid engine where judgement matters and mistakes compound; use the free
engine where the work is routine and CI catches errors:

| Job | Engine | Why |
|---|---|---|
| `--init`, `--replan` | claude | A bad plan becomes twenty bad PRs. This is exactly where model quality pays. |
| Routine plan items | opencode | CI is the safety net; free is fine. |
| Items the free model failed twice | claude | Cheaper than a third failed attempt. |
| CI-fix `--task` on a stuck PR | claude | Small, surgical, benefits from a strong model. |

### Cost visibility

Claude Code's final log event includes the session cost, and `run.sh` prints it
after each run:

```
  session cost: $0.4231
```

Watch it for the first few runs. API billing is per token — a heavy item can
cost real money, which is also why the plan/loop split above exists. The
container and all guardrails behave identically to the free engine;
`bypassPermissions` is as safe here as it is there, because the boundary is
Docker, not the permission prompt.

---

## How the loop stays honest

**Bash picks the item.** `run.sh` greps the first `- [ ]` from `PLAN.md` and puts
that exact text in the prompt. Selection never goes through the model.

**The loop waits for the merge.** After the PR opens, `run.sh` polls GitHub —
no tokens, no agent turns, one containerized `gh` call per poll using the
agent's own scoped token, so the host needs no GitHub login at all. This is
required, not a nicety: until the merge lands, `PLAN.md` on `main` still shows
the item unchecked, so the next iteration would redo it. `--no-wait` skips the
wait and warns about exactly this.

**Verification's ground truth is GitHub, not local git.** The agent commits
inside the container, and the host's view of refs on a macOS bind mount can lag
those writes — early versions trusted `git log` locally and produced false
"nothing happened" verdicts for sessions that had opened perfectly good PRs.
Each iteration now asks GitHub whether a PR exists for the work branch; local
commits are only a fallback diagnostic. Exit codes are trusted least of all —
"exit 0" doesn't mean the work happened, and non-zero doesn't mean it didn't.

**On CI failure, the log goes back to the agent.** `wait_for_merge` detects a
red PR, bash fetches the failing job's log tail via the Actions API, switches
to the PR branch, and runs a fix session — up to `--ci-retries` times. Bash
does the deterministic parts (log fetching, branch switching); the model only
fixes code.

**Growth is measured.** Added items are computed from the done/remaining deltas,
printed, and capped.

---

## Graphify: why token usage stays low

Graphify parses the repo with tree-sitter and builds a knowledge graph — which
function calls which, which module imports what, where each type is used. The
agent queries that graph instead of reading files.

In practice: instead of "read `src/auth/session.py`" (thousands of tokens, most
irrelevant), the agent asks "what does `authenticate_user` depend on?" and gets
back a handful of lines with `file:line` citations. The project's own benchmark
claims ~71× fewer tokens; what you actually get depends on repo size and whether
your model bothers to use the tools — which is why 6.3 has you check for
`graphify_*` calls on the very first run.

Mechanics, all handled for you:

- `run.sh` refreshes the index before every task (`graphify update`, incremental
  via per-file SHA256, fast after the first build).
- Indexing uses `--code-only`: pure tree-sitter, **no LLM calls, no API key, no
  network**. Works in a sealed container.
- `AGENTS.md` tells the agent to query the graph before opening files and names
  the tools. Without that instruction the MCP server sits unused — wiring it up
  is not enough, because the model defaults to reading files out of habit.
- `graphify-out/` is gitignored. It's regenerated locally; committing it would
  put a large JSON diff in every PR and cause merge conflicts.
- Failures are non-fatal. `run.sh` warns and continues. `--no-graph` skips it
  entirely. It's an optimisation, never a dependency.

One caveat: edges marked `INFERRED` are model-generated guesses rather than
parsed facts. `AGENTS.md` tells the agent to verify those against the real file
before relying on them.

---

## Why Docker means less configuration

Counterintuitive, but the container removes a bigger layer than it adds.

**Without Docker:** telling the agent never to ask means it can reach `~/.ssh`,
your other repositories, your documents. Preventing that takes long deny lists,
guard hooks and path rules — and you can never be sure you didn't miss one.

**With Docker:** the container only sees the repository. The worst it can do is
damage a git-tracked repo. So you can afford to say "allow everything" and mean
it. No deny list, because the operating system draws the boundary.

That's why `opencode.json` has one `"*": "allow"` line and no hook script. The
`deny` rules that remain cover the only thing the container can't protect: the
remote git history and real infrastructure. GitHub's branch protection covers the
same ground independently — three layers, none of which relies on the model
behaving.

---

## Division of responsibility

```
BASH (run.sh)              AGENT (container)          GITHUB
──────────────────         ──────────────────         ──────────────
pick next item             query the graph            run CI
refresh graph index        write code                 auto-merge if green
verify commits exist       run tests, fix             tag via release-please
verify PR opened           tick the checkbox
verify checkbox moved      append discovered work
measure plan growth        push + open PR
wait for merge             stop
stop on failure
```

Everything deterministic lives in bash or GitHub. The agent does the parts that
genuinely need a model: writing code, and noticing what else the project needs.

---

## Token and context budget

On OpenRouter's free tier the scarce resource is REQUESTS (20/min, 1000/day),
not tokens — tokens cost $0. Bloated context still hurts, indirectly: it
forces OpenCode's automatic compaction (summarisation = lost detail + extra
requests), slows every step, and can overflow the model's window entirely.
The defence has four layers:

1. **Graphify** (already installed): the agent queries a knowledge graph over
   MCP instead of reading whole files.
2. **opencode.json settings** (in the template): `compaction.prune: true`
   drops old tool outputs from the context instead of carrying them forever;
   `tool_output: {max_lines: 500, max_bytes: 20480}` truncates giant command
   outputs at the source (the full text is saved to disk in the container and
   the agent can grep it if needed); `setCacheKey: true` pins OpenRouter
   routing to one provider so prompt caches stay warm.
3. **AGENTS.md output discipline**: the agent is instructed to run tests
   quietly, tail long outputs, and grep before reading.
4. **Headroom (optional, `--headroom`)**: an in-container proxy that
   compresses old tool outputs (locally, reversibly — nothing leaves the
   machine) before each request. Adds a moving part; measure first — enable
   it if the "session tokens" line in run summaries keeps growing past the
   model's context size, i.e. compaction is triggering anyway. Requires a
   rebuilt image (`docker build -t agent -f Dockerfile.agent .`).

Paid engines cache automatically — nothing to configure: Claude Code applies
Anthropic prompt caching in headless `-p` mode by itself (cache reads are
~10x cheaper, this is where the real money is saved), and Codex gets OpenAI's
automatic prefix caching for prompts over ~1-2k tokens. What YOU control on
paid engines is prefix stability: `AGENTS.md` and `CLAUDE.md` are the cached
prefix, so keep them lean and change them rarely — every edit invalidates
the cache once.

---

## How releases work

> **If no release PR appears after an auto-merge:** merges performed with the
> default `GITHUB_TOKEN` do not trigger `on: push` workflows (GitHub's
> recursion guard), so release-please never runs on bot-merged commits. Fix:
> add a repo secret `AUTOMERGE_TOKEN` (Settings → Secrets and variables →
> Actions) containing a PAT with Contents + Pull requests write — the
> gh-agent token works — and `automerge.yml` will merge with it. One-off
> workaround: Actions → release → Run workflow, or just push any commit.

A recurring confusion, worth its own mental model: **merged code is not
released code.** `main` is a continuously written ledger; a release is the act
of stamping "everything up to HERE is vX.Y.Z" — a git tag, a changelog entry,
and a human decision about the moment.

The release PR (opened by release-please from its own branch
`release-please--branches--main`) carries **no code** — its diff is just the
changelog bookkeeping. It exists for two reasons: the changelog is a file on
protected `main` (so it must travel like any change), and a release is a
*decision*, not an automatic consequence of merging. The open PR is a standing
question — "cut it now?" — that keeps updating itself as feats land. Your merge
is the answer: that merge triggers the release workflow, which creates the tag
**at that commit** plus the GitHub release.

Practical rules that follow: merge the release PR between runs, never during
one; batch it (merging after every feat produces version-number sprawl — one
merge at end-of-day gives one clean version); and with hatch-vcs the tag IS the
package version, so the two can never desync. Commit types drive the numbers:
`fix:` → patch, `feat:` → minor, `feat!:` → major; `chore:`/`ci:`/`docs:`
neither trigger nor appear.

---

## Notes

**CI plan items work through proposals.** The agent can't touch
`.github/workflows/` (denied by config, and its token lacks the Workflows
permission, so GitHub rejects such pushes regardless). Plan items about CI are
still fine: the agent writes the proposed workflow to `ci-proposals/<name>.yml`
— inert by location — and the PR tells you the one `git mv` that applies it.
Deliberate: an agent that can edit its own gate can learn to pass by weakening
it.

**Item quality is the whole game.** One PR per item, independently testable,
ordered so each depends only on items above it, written as an instruction rather
than a topic. "Add rate limiting to the login endpoint" finishes in 8 turns;
"rewrite the auth module" burns 40 and breaks halfway.

**Flaky tests are the loop's worst enemy.** A nondeterministic test (unseeded
RNG, time-dependent assertion) turns your merge gate into a dice roll: the
agent's correct PR fails randomly, `--ci-retries` burns sessions on unfixable
"failures", and trust in red erodes. When one surfaces, fixing it IS the next
task — seed the RNG or assert the real contract.

**Long test suites vs the agent's shell timeout.** The agent's in-container
commands time out around two minutes; a 10-minute suite cannot be verified
locally by it, so it silently falls back to letting CI be the judge. Give it a
fast targeted command in `AGENTS.md`'s Project reference (e.g.
`uv run pytest -q -x tests/unit`) alongside the full-suite command CI runs.

**While a run is in progress, the repo is the agent's.** Same checkout, same
branches: don't run git commands in it, and don't merge other PRs (the
"branch must be up to date" rule would strand the agent's PR). Your commits
and merges happen between runs, from `main`.

**Rate limits.** OpenRouter caps free models at 20 requests/minute regardless of
credit, and 1,000 requests/day once you've put $10 on the account (50/day below
that, which is not enough to run this). The loop is serial by design, so you
won't hit the per-minute ceiling — but don't run two copies of `run.sh` at once.

**The cache volume.** First run is slow; later ones reuse `agent-cache` for
`uv`/`npm` downloads. Reset with `docker volume rm agent-cache`.

**No `~/.ssh` mount.** The agent pushes over HTTPS with `GH_TOKEN`. Keeping keys
out of the container entirely is cleanest.

**Token expiry.** The agent's fine-grained token expires (90 days if you took the
suggestion). Symptom: `git push` fails with `403`. Regenerate and update the
keychain entry.

**File permission errors.** If container-written files show up with odd
ownership, add `--user "$(id -u):$(id -g)"` to the `docker run` in `run.sh`.

---

## Every stop message and what to do

`run.sh` stops loudly rather than continuing on a bad assumption. Here's each
message.

### `STOPPING: no commits were made.`

The agent produced nothing. Almost always the model failing at tool calls.

```
$ jq -r 'select(.type=="tool_use") | .tool // .name' logs/<latest>.jsonl | sort | uniq -c
```

No `bash` or `edit` entries → change the model in `opencode.json`. Some entries
but it gave up → the item is probably too big; split it in `PLAN.md`.

### `STOPPING: commits exist but no pull request was opened.`

Code was written but `gh pr create` failed. Usually the token.

```
$ docker run --rm -e GH_TOKEN="$(security find-generic-password -s gh-agent -w)" agent gh auth status
```

If that fails, the token expired or lacks Pull requests: write. Regenerate it
(4.2). Then push and open the PR by hand — the work isn't lost.

### `WARNING: the item was not ticked off in PLAN.md`

The agent did the work but skipped step 5 of `AGENTS.md`. Without the tick, the
next iteration would redo the same item, so the loop refuses to continue. Tick it
yourself:

```
$ git switch main && git pull
$ # edit PLAN.md, change the item's [ ] to [x]
$ git commit -am "chore: tick completed plan item" && git push
```

If it happens repeatedly, the model isn't following instructions reliably enough
for this setup. Change it.

### `STOPPING: CI failed on PR #N.`

Expected occasionally. Fix on the same branch so the existing PR updates:

```
$ gh pr checks N                    # what failed
$ gh run view --log-failed          # the actual error
$ git switch $(gh pr view N --json headRefName -q .headRefName)
$ ./run.sh --task "CI failed with: <paste the error>. Fix it."
$ git push
```

If the same class of failure keeps happening, your CI and `AGENTS.md` disagree
about what "green" means. Make them identical.

### `STOPPING: PR #N did not merge.`

Timed out or the PR was closed. Check:

```
$ gh pr view N --json state,mergeStateStatus,labels
```

- `BLOCKED` → a required check hasn't reported. Name mismatch: re-run
  `CHECK=<job-name> ./setup-github.sh`
- `CLEAN` but not merged → auto-merge isn't on. See 4.3.
- label `blocked` → the agent flagged it deliberately. Read the description.

### `STOPPING: the agent has added N items this run`

Plan growing faster than it shrinks. Either the items are too broad (each one
uncovers three more) or the model is padding.

```
$ ./run.sh --replan              # prune and consolidate
$ ./run.sh -n 5 --no-discover    # or turn discovery off for a while
```

### `error: image 'agent' not found`

```
$ docker build -t agent -f Dockerfile.agent .
```

### `error: Docker is not running`

```
$ colima start
```

### `error: keychain entry 'X' not found`

```
$ security add-generic-password -s X -a "$USER" -w '<secret>'
```

### `PLAN.md not found`

```
$ ./run.sh --init "<description>"
```

---

## Quick reference

### Daily commands

```bash
./run.sh                      # next item
./run.sh -n 5                 # next five
./run.sh -n all               # until the plan is done
./run.sh --next               # what's next (free, no API calls)
./run.sh --task "fix X"       # one-off, ignores PLAN.md
./run.sh --replan             # restructure the plan
./run.sh --reindex            # rebuild the graph
./run.sh --help               # all flags
```

### Files you edit

| File | When |
|---|---|
| `PLAN.md` | Adding work, fixing order, pruning |
| `AGENTS.md` → Project reference | Commands changed |
| `opencode.json` | Changing model or guardrails |
| `Dockerfile.agent` | Agent needs a new tool |
| `.github/workflows/ci.yml` | CI changed |

### Files you don't touch

| File | Why |
|---|---|
| `run.sh` | The loop logic; changing it breaks the safety checks |
| `setup-github.sh` | Run once, done |
| `automerge.yml`, `release.yml` | Work as-is |

### Health check in one command

```bash
./run.sh --next && \
gh pr list --label blocked && \
jq -r 'select(.type=="tool_use") | .tool // .name' logs/*.jsonl \
  | sort | uniq -c | sort -rn | head
```

Where the plan stands, what needs you, and whether the agent is using tools
properly.

---

## Later: reuse the same image in CI

Push `Dockerfile.agent` to GHCR and CI runs in the identical environment, which
eliminates the whole "works locally, fails in CI" category:

```yaml
jobs:
  ci:
    runs-on: ubuntu-latest
    container: ghcr.io/<user>/agent:latest
    steps:
      - uses: actions/checkout@v4
      - run: uv run ruff check . && uv run pytest -q
```

Later still, you can run the agent itself inside GitHub Actions with OpenCode's
`/oc` bot (`opencode github install`). The same `opencode.json` and `AGENTS.md`
apply there, so this setup doesn't lock you in.

---

## References

- [OpenCode — permissions](https://opencode.ai/docs/permissions/)
- [OpenCode — config](https://opencode.ai/docs/config/)
- [OpenCode — MCP servers](https://opencode.ai/docs/mcp-servers/)
- [OpenCode — CLI (`run`, `--format json`)](https://opencode.ai/docs/cli/)
- [OpenCode — rules / AGENTS.md](https://opencode.ai/docs/rules/)
- [OpenCode — models & tool calling](https://opencode.ai/docs/models/)
- [Graphify — repository](https://github.com/Graphify-Labs/graphify)
- [Graphify — docs](https://graphify.com/docs)
- [Graphify — MCP tool reference](https://graphify.com/docs/mcp-tools)
- [Graphify — PyPI (`graphifyy`)](https://pypi.org/project/graphifyy/)
- [OpenRouter — models with tool calling](https://openrouter.ai/collections/tool-calling-models)
- [OpenRouter — free models](https://openrouter.ai/collections/free-models)
- [GitHub — branch protection API](https://docs.github.com/en/rest/branches/branch-protection)
- [release-please action](https://github.com/googleapis/release-please-action)
