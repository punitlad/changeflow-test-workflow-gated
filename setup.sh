#!/usr/bin/env bash
# One-time GitHub-side setup for the workflow_gated test target.
# Requires: gh CLI authenticated (`gh auth login`) with admin on the target owner/org.
set -euo pipefail

: "${GH_OWNER:?set GH_OWNER to your github user or org}"
: "${REPO_NAME:=changeflow-test-workflow-gated}"
REVIEWER_LOGIN="${REVIEWER_LOGIN:-punitlad}"

echo "==> Repo: $GH_OWNER/$REPO_NAME"

if gh repo view "$GH_OWNER/$REPO_NAME" >/dev/null 2>&1; then
  echo "    already exists, pushing current content"
  git remote add origin "https://github.com/$GH_OWNER/$REPO_NAME.git" 2>/dev/null || true
  git push -u origin main
else
  echo "    creating + pushing"
  gh repo create "$GH_OWNER/$REPO_NAME" --public --source=. --remote=origin --push
fi

echo "==> Creating 'production' environment with $REVIEWER_LOGIN as required reviewer"
REVIEWER_ID=$(gh api "users/$REVIEWER_LOGIN" --jq .id)
gh api -X PUT "repos/$GH_OWNER/$REPO_NAME/environments/production" --input - >/dev/null <<EOF
{
  "reviewers": [{"type": "User", "id": $REVIEWER_ID}],
  "deployment_branch_policy": null
}
EOF

cat <<MSG

Done. No branch ruleset needed for this mode -- see README.md for why.

Remaining manual steps:
  1. Install the GitHub App on this repo:
     https://github.com/settings/apps/my-changeflow-app -> Install App -> $GH_OWNER/$REPO_NAME
  2. auto-merge.yml's \`if:\` already assumes the bot login 'my-changeflow-app[bot]',
     confirmed against a real PR for that App -- if you're pointing this at a differently
     named App, update the login in .github/workflows/auto-merge.yml first.

Then point changeflow at it (see README.md "Run changeflow against it").
MSG
