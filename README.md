# changeflow test target: `workflow_gated`

Validates `CHANGEFLOW_MERGE_MODE=workflow_gated` — changeflow does nothing to merge the PR
(`WorkflowGatedMerge.ensure_merging` is a no-op); this repo's own `auto-merge.yml` sees the PR
author is the App's bot login and merges it.

## What's here

| File | Purpose |
|---|---|
| `teams.json` | The file changeflow appends `{"team": "<name>"}` to |
| `.github/workflows/auto-merge.yml` | `pull_request_target` workflow that allow-lists the App by **author** and merges |
| `.github/workflows/deploy.yml` | The pipeline triggered by the merge, gated by the `production` environment |
| `setup.sh` | One-time `gh` CLI setup for this repo (environment only — no ruleset needed) |

## Why this mode specifically needs this layout

The trust logic lives entirely in `auto-merge.yml`'s `if:` condition — it checks
`github.event.pull_request.user.login`, **not** a label or PR title, per the main README's
"Watch out for" callout (a label/title check is spoofable by anyone who can open a PR; the
author field on a bot-authored PR isn't). No branch ruleset is required for this mode to work,
since the merge isn't going through GitHub's native auto-merge or a bypass — it's an ordinary
`gh pr merge` call from a workflow using the default `GITHUB_TOKEN`.

**Known placeholder to fix:** `auto-merge.yml` currently checks for login
`my-changeflow-app[bot]`. Confirm that's the real author login changeflow's PRs show up
with (it should be, for a GitHub App named `my-changeflow-app`, but verify against one real
PR before relying on this in anger).

## One-time setup

```bash
export GH_OWNER=<your-github-user-or-org>
export REPO_NAME=changeflow-test-workflow-gated
./setup.sh
```

`setup.sh` will:
1. `gh repo create` (if `REPO_NAME` doesn't exist yet) and push this directory to it
2. Create the `production` environment with `punitlad` as a required reviewer

Then **install your GitHub App on this repo**.

## Run changeflow against it

```bash
export CHANGEFLOW_TARGET_OWNER=$GH_OWNER
export CHANGEFLOW_TARGET_REPO=$REPO_NAME
export CHANGEFLOW_MERGE_MODE=workflow_gated
export CHANGEFLOW_APPROVAL_MODE=pending_deployments
export CHANGEFLOW_PIPELINE_ENVIRONMENT=production
export CHANGEFLOW_APPROVER_TOKEN=<a PAT for punitlad with repo + workflow scope>
# ...plus CHANGEFLOW_APP_ID / CHANGEFLOW_APP_PRIVATE_KEY / CHANGEFLOW_INSTALLATION_ID
uvicorn changeflow.api:app
curl -XPOST localhost:8000/team-onboardings -d '{"team":"payments","requested_by":"you"}'
```

## What "validated" looks like

`GET /team-onboardings/{id}` reaches `phase: succeeded`, with the PR's merge visible on GitHub
as done by `auto-merge-changeflow-prs` (check its run log), not by changeflow's own API calls —
confirming `wait_until_merged`'s polling, not any merge call, is what's doing the work in this
mode.
