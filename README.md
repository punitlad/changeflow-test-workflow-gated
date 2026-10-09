# changeflow test target: `workflow_gated`

Validates `CHANGEFLOW_MERGE_MODE=workflow_gated` — changeflow does nothing to merge the PR
(`WorkflowGatedMerge.ensure_merging` is a no-op); this repo's own `auto-merge.yml` sees the PR
author is the App's bot login and merges it. **Validated end-to-end.**

## What's here

| File | Purpose |
|---|---|
| `teams.json` | The file changeflow appends `{"team": "<name>"}` to |
| `.github/workflows/auto-merge.yml` | `pull_request_target` workflow that allow-lists the App by **author** and merges, using a PAT |
| `.github/workflows/deploy.yml` | The pipeline triggered by the merge, gated by the `production` environment |
| `setup.sh` | One-time `gh` CLI setup for this repo (environment only — no ruleset needed) |

## Why this mode specifically needs this layout

The trust logic lives entirely in `auto-merge.yml`'s `if:` condition — it checks
`github.event.pull_request.user.login`, **not** a label or PR title, per the main README's
"Watch out for" callout (a label/title check is spoofable by anyone who can open a PR; the
author field on a bot-authored PR isn't). No branch ruleset is required for this mode to work,
since the merge isn't going through GitHub's native auto-merge or a bypass — it's an ordinary
`gh pr merge` call from a workflow.

### Gotcha found by testing this for real: the merge step cannot use the default `GITHUB_TOKEN`

The first version of `auto-merge.yml` merged with `secrets.GITHUB_TOKEN`. The PR merged fine,
but `deploy.yml` never ran — GitHub doesn't let a push made with the default `GITHUB_TOKEN`
trigger other workflows (loop prevention by design), so changeflow's `find_run()` timed out
waiting for a `deploy.yml` run that was never going to happen. Fix: merge with a **PAT**
instead, stored as a repo secret:

```bash
gh secret set MERGE_TOKEN -R <owner>/<repo>
```

(paste a PAT for the reviewer identity, scopes `repo` + `workflow`, when prompted — not
through any automation, it should be a manual, interactive step). `auto-merge.yml` already
references `secrets.MERGE_TOKEN`; this secret is the one thing `setup.sh` can't create for you.

## One-time setup

```bash
export GH_OWNER=<your-github-user-or-org>
export REPO_NAME=changeflow-test-workflow-gated
export REVIEWER_LOGIN=<github-login-for-the-required-reviewer>   # defaults to punitlad
./setup.sh
```

`setup.sh` will:
1. `gh repo create` (if `REPO_NAME` doesn't exist yet) and push this directory to it
2. Create the `production` environment with `$REVIEWER_LOGIN` (`punitlad` by default) as a
   required reviewer

Then, in order:
1. **Install your GitHub App on this repo.**
2. **Set the `MERGE_TOKEN` secret** (see above) — `auto-merge.yml` can't merge anything
   without it.
3. Confirm the bot login in `auto-merge.yml`'s `if:` condition (`my-changeflow-app[bot]`)
   matches your actual App's slug — different App name, different login.

## Run changeflow against it

```bash
export CHANGEFLOW_TARGET_OWNER=$GH_OWNER
export CHANGEFLOW_TARGET_REPO=$REPO_NAME
export CHANGEFLOW_MERGE_MODE=workflow_gated
export CHANGEFLOW_APPROVAL_MODE=pending_deployments
export CHANGEFLOW_PIPELINE_ENVIRONMENT=production
export CHANGEFLOW_APPROVER_TOKEN=<a PAT for whoever REVIEWER_LOGIN was set to (punitlad by default), with repo + workflow scope>
# ...plus CHANGEFLOW_APP_ID / CHANGEFLOW_APP_PRIVATE_KEY / CHANGEFLOW_INSTALLATION_ID
uvicorn changeflow.api:app
curl -XPOST localhost:8000/team-onboardings -d '{"team":"payments","requested_by":"you"}'
```

## What "validated" looks like

`GET /team-onboardings/{id}` reaches `phase: succeeded`, with the PR's merge visible on GitHub
as done by `auto-merge-changeflow-prs` (check its run log, `merged_by` on the PR shows
`github-actions[bot]`), not by changeflow's own API calls — confirming `wait_until_merged`'s
polling, not any merge call, is what's doing the work in this mode. `deploy.yml` shows a
`push`-triggered run matching the merge SHA, confirming the `MERGE_TOKEN` fix actually works.

## Trade-offs for team discussion

- **Lowest trust grant of the three** — the App never gets elevated merge/bypass rights on the
  target repo at all; the target repo's own team-owned workflow does the merging, using a PAT
  *they* control.
- **Their maintenance burden, not ours** — if their CI/CD conventions change (workflow
  triggers, token policy, branch names), their workflow can silently stop merging our PRs and
  we won't find out until a job times out waiting for a merge that never happens.
- **The `GITHUB_TOKEN` gotcha above is a real trap** for whoever on their side implements this
  — worth flagging explicitly when asking a team to adopt this mode, not just linking them our
  README.
