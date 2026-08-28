#!/usr/bin/env bash
# One-time GitHub setup: branch protection + auto-merge.
# This is your last line of defence if the agent misbehaves.
# Run it once and forget it.
#
# Two ways to run it — both need ADMIN permission on the repo:
#   In the container (no host gh login needed):
#     security add-generic-password -s gh-admin -a "$USER" -w '<admin PAT>'
#     ./run.sh --github-setup
#   On the host, with your own gh session:
#     ./setup-github.sh

set -euo pipefail

command -v gh >/dev/null || { echo "error: gh CLI not found"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "error: no gh credentials (login with 'gh auth login' or provide GH_TOKEN)"; exit 1; }

REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
CHECK="${CHECK:-}"       # empty = auto-detect from the checks that ran on main

# ── Resolve the required status check name ───────────────────────────────────
# Branch protection that requires a check which never reports = nothing ever
# merges, silently. So instead of guessing, ask GitHub which checks actually
# ran on main and validate/auto-detect against that list.
detect_checks() {
  local sha
  sha="$(gh api "repos/$REPO/branches/main" --jq .commit.sha 2>/dev/null)" || return 0
  gh api "repos/$REPO/commits/$sha/check-runs" --paginate \
    --jq '.check_runs[].name' 2>/dev/null | sort -u
}
NAMES="$(detect_checks || true)"

if [[ -n "$CHECK" ]]; then
  if [[ -n "$NAMES" ]] && ! grep -qxF "$CHECK" <<<"$NAMES"; then
    echo "error: no check named '$CHECK' has reported on main." >&2
    echo "Checks seen on main:" >&2
    sed 's/^/  - /' <<<"$NAMES" >&2
    echo "Re-run with CHECK set to one of the above." >&2
    exit 1
  fi
elif [[ -n "$NAMES" ]] && grep -qxF "ci" <<<"$NAMES"; then
  CHECK="ci"
elif [[ -n "$NAMES" && "$(wc -l <<<"$NAMES" | tr -d ' ')" == "1" ]]; then
  CHECK="$NAMES"
  echo "note: auto-detected required check '$CHECK' (the only check reporting on main)"
elif [[ -z "$NAMES" ]]; then
  CHECK="ci"
  echo "note: no check runs found on main yet — defaulting to 'ci'."
  echo "      If your CI job is named differently, re-run with CHECK=<name>."
else
  echo "error: several checks report on main and none is named 'ci':" >&2
  sed 's/^/  - /' <<<"$NAMES" >&2
  echo "Pick the one that must gate merges:" >&2
  echo "  CHECK=<name> ./run.sh --github-setup     (or CHECK=<name> ./setup-github.sh)" >&2
  exit 1
fi

echo "repo:            $REPO"
echo "required check:  $CHECK"
echo
if [[ "${AGENTLOOP_YES:-}" == "1" ]]; then
  echo "AGENTLOOP_YES=1 — proceeding without confirmation."
else
  read -rp "This will lock down main and enable auto-merge. Continue? [y/N] " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || { echo "aborted."; exit 0; }
fi

echo
echo "> branch protection (main)"
gh api -X PUT "repos/$REPO/branches/main/protection" \
  --input - <<EOF
{
  "required_status_checks": {
    "strict": true,
    "contexts": ["$CHECK"]
  },
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "required_approving_review_count": 0,
    "dismiss_stale_reviews": false
  },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false
}
EOF
echo "  OK  main protected: force push off, CI required"

echo
echo "> repository settings"
gh repo edit --enable-auto-merge --enable-squash-merge --delete-branch-on-merge
echo "  OK  auto-merge + squash + delete branch on merge"

echo
echo "> labels"
gh label create automated --color 0e8a16 --description "Opened by the agent, auto-merge when green" --force >/dev/null
gh label create blocked   --color d93f0b --description "Agent is stuck, needs a human" --force >/dev/null
gh label create plan      --color 1d76db --description "Change to PLAN.md, review before merging" --force >/dev/null
echo "  OK  automated, blocked, plan"

cat <<'EOF'

========================================================
Done. Two manual steps remain:

1) Give the agent token access to this repo.
   ONE token serves all your agentloop projects — if you already have it,
   just add this repo to its list:
     github.com/settings/personal-access-tokens
       -> your agent token -> Repository access -> add this repo
   Creating it for the first time:
     github.com/settings/personal-access-tokens/new
     · Repository access -> Only select repositories -> your agentloop repos
     · Permissions -> Contents: Read and write
     · Permissions -> Pull requests: Read and write
     · Permissions -> Checks: Read-only          (CI verdict polling)
     · Permissions -> Commit statuses: Read-only (CI verdict polling)
     · Select NOTHING else (no admin, no org scopes)

   Then store it in the keychain:
     security add-generic-password -s gh-agent -a "$USER" -w 'github_pat_...'

2) Let Actions open and merge pull requests:
   Settings -> Actions -> General -> Workflow permissions
     · Select "Read and write permissions"
     · Check "Allow GitHub Actions to create and approve pull requests"
========================================================
EOF
