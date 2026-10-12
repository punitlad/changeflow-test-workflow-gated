# changeflow test target: `workflow_gated`

Validates `CHANGEFLOW_MERGE_MODE=workflow_gated` — changeflow does nothing to merge the PR
(`WorkflowGatedMerge.ensure_merging` is a no-op); this repo's own `auto-merge.yml` sees the PR
author is the App's bot login and merges it once the required check is green. **Validated
end-to-end.**

## Fixed: this target used to have no PR-time check and no branch ruleset at all

Earlier versions of this repo shipped with neither `ci.yml` nor a branch ruleset — the reasoning
was "the merge isn't going through native auto-merge or a bypass, so no ruleset is needed." That
was true for the *API's* path, but it quietly meant **humans merging here had less protection
than `base-repo`'s own pattern gives them** — anyone could merge straight to `main` with nothing
checked. That's a regression to the human path, not an add-on for the API, which is exactly the
thing this whole test-repos exercise is supposed to avoid. Both are restored now: `ci.yml`
(copied from `base-repo`) and the same ruleset `native-auto-merge` uses (PR + required `validate`
check, no bypass actor, no required review). **Re-validated end-to-end after the fix** (PR #6) —
`pr_open → merging → merged → pipeline_running → succeeded` in ~36s.

Two bugs only surfaced once this was run for real against live GitHub, both now fixed (PRs #4, #5):
- `gh pr view`/`gh pr merge` need `-R owner/repo` explicitly — `auto-merge.yml` has no
  `actions/checkout` step, so there's no local git repo for the `gh` CLI to infer the target
  repo from. Failed with `fatal: not a git repository`.
- `gh pr view --json author` (GraphQL-backed) renders a bot's login as `app/<slug>`, **not**
  `<slug>[bot]` — that suffix form is the REST/webhook convention (`github.actor`,
  `github.event.pull_request.user.login`), which is what `ci.yml` and this file's own `if:`
  elsewhere compare against. The first version of the author check used the wrong format and
  silently treated the App's own PR as a human's, every time — it never errored, it just never
  merged anything.

## What's here

| File | Purpose |
|---|---|
| `teams.json` | The file changeflow appends `{"team": "<name>"}` to |
| `.github/workflows/ci.yml` | PR-time required check (`validate`) — same for both paths |
| `.github/workflows/auto-merge.yml` | Fires on `ci.yml`'s completion, confirms the App authored the PR, and merges with a PAT |
| `.github/workflows/deploy.yml` | The pipeline triggered by the merge, gated by the `production` environment |
| `setup.sh` | One-time `gh` CLI setup for this repo (ruleset + environment) |

## Why this mode specifically needs this layout

The trust logic lives entirely in `auto-merge.yml`'s `if:` condition — it checks the PR's author
login, **not** a label or PR title, per the main README's "Watch out for" callout (a label/title
check is spoofable by anyone who can open a PR; the author field on a bot-authored PR isn't).

Unlike the original version of this target, there **is** a branch ruleset now, and `auto-merge.yml`
has to respect it rather than race it: it's triggered by `workflow_run: ["ci"], types: [completed]`
instead of `pull_request_target: [opened, ...]`, so it only ever tries to merge after the required
`validate` check has actually gone green. Merging at PR-open time (the old trigger) would often
hit the check before it finished and get a 422 from the ruleset. The App isn't on the ruleset's
bypass list here — same required check, same ruleset, it just gets satisfied by a workflow instead
of a human clicking merge.

One quirk worth knowing if you edit `auto-merge.yml`: a `workflow_run` listener always executes the
copy of *itself* committed on the default branch (`main`), not the version in the PR branch — so a
change to this file only takes effect on PRs opened after it's merged to `main`.

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
2. Create a branch ruleset on `main`: require a pull request + the `validate` status check,
   no bypass actor, no required reviewers
3. Create the `production` environment with `$REVIEWER_LOGIN` (`punitlad` by default) as a
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
Also confirm `validate` actually ran and passed *before* the merge — check the timestamps, or
briefly break `ci.yml` to confirm the merge no longer happens until it's fixed.

For the human path: open a PR by hand and confirm it's genuinely blocked from merging until
`validate` passes — this used to not be true at all on this target.

## Trade-offs for team discussion

- **Lowest trust grant of the three** — the App never gets elevated merge/bypass rights on the
  target repo at all; the target repo's own team-owned workflow does the merging, using a PAT
  *they* control, and now goes through the same required check a human would.
- **Their maintenance burden, not ours** — if their CI/CD conventions change (workflow
  triggers, token policy, branch names), their workflow can silently stop merging our PRs and
  we won't find out until a job times out waiting for a merge that never happens.
- **The `GITHUB_TOKEN` gotcha above is a real trap** for whoever on their side implements this
  — worth flagging explicitly when asking a team to adopt this mode, not just linking them our
  README.
- **One extra round-trip vs. the original design.** Waiting for `workflow_run: [completed]`
  instead of merging at PR-open time adds however long `validate` takes before `auto-merge.yml`
  even starts — a deliberate trade for correctness (not racing the ruleset), but worth knowing
  it's slower than the original, broken version was.
