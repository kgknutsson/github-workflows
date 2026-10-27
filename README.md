# github-workflows
Reusable GitHub Workflows (v4 development on branch `dev`).

## azure-app-service-slot-promotion.yml

Safe staging → production promotion with AutoSwap preflight, bounded health gates, ARM `slotsswap` with async/activity-log reconciliation, and fail-closed HTTP 409 / 04026 handling. See [docs/azure-app-service-slot-promotion.md](docs/azure-app-service-slot-promotion.md).

Pin `@dev` or `@v4` and set matching `scripts-ref`.

Optional input `manage_deploy_slot_lifecycle` (default `false`): when `true`, starts the staging slot before deploy or health checks and stops it after production health passes.

## azure-webapp-zip-deploy.yml

Direct zip deploy to a Web App slot with a post-deploy health gate. Use for dev (production slot) while prod uses `azure-app-service-slot-promotion.yml`. See [docs/azure-webapp-zip-deploy.md](docs/azure-webapp-zip-deploy.md).

## azure-app-service-slot-swap-recovery-preflight.yml

Callable preflight for slot-swap recovery metadata (and optional production health URL). Cron and full reconciliation stay in the consumer repo. See [docs/slot-swap-guards-and-recovery.md](docs/slot-swap-guards-and-recovery.md) and [docs/examples/recover-slot-swap-cron-wrapper.yml](docs/examples/recover-slot-swap-cron-wrapper.yml).

## SPA App Service pull request preview

`spa-app-service-pr-preview.yml` builds a Node app and zip-deploys it to one preview slot. It creates the slot when the slot is missing. It does not apply Terraform and it does not swap the slot to production.

`spa-app-service-pr-preview-cleanup.yml` deletes that slot and the preview comment.

`spa-app-service-pr-preview-orphan-cleanup.yml` deletes `pr-*` slots whose pull request is not open.

The caller owns `pull_request`, path filters, the schedule, and the preview comment. See `docs/spa-app-service-pr-preview.md`.

## Terraform CI, plan, and apply

`terraform-ci.yml`, `terraform-plan.yml`, and `terraform-apply.yml` are callable workflows. The caller owns triggers. See `docs/terraform-ci-plan-apply.md`.

## prod-deploy-slack-notify.yml

Reusable workflow that posts Slack messages when a **production** GitHub Actions deployment starts and when it finishes (success or failure).

Staging, test, preview, and other non-production GitHub environments do not send messages. The workflow skips when `environment` is not listed in `production_environment_names`.

### Repository secret (caller)

Add this secret on each repository that calls the workflow:

| Secret | Required | Description |
| --- | --- | --- |
| `PRODUCTION_DEPLOY_SLACK_WEBHOOK_URL` | Yes | Incoming webhook URL for the dedicated production-deploys Slack channel. |

Pass the secret into the reusable workflow with `secrets.PRODUCTION_DEPLOY_SLACK_WEBHOOK_URL`.

### Inputs (caller)

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `notification_phase` | Yes | — | `start` before deploy, or `complete` after deploy. |
| `environment` | Yes | — | GitHub Actions environment name (for example `prod`). |
| `service_name` | Yes | — | Application or service name in the message. |
| `production_environment_names` | No | `prod,production` | Comma-separated names treated as production. |
| `deployment_result` | When `complete` | — | `needs.<job>.result` from the deploy job. |

### Example (not wired by default)

Call twice from a deploy workflow: once at start and once after the deploy job with `if: always()`.

```yaml
jobs:
  slack-notify-start:
    if: github.actor != 'dependabot[bot]'
    uses: kgknutsson/github-workflows/.github/workflows/prod-deploy-slack-notify.yml@dev
    with:
      notification_phase: start
      environment: prod
      service_name: my-service
    secrets:
      PRODUCTION_DEPLOY_SLACK_WEBHOOK_URL: ${{ secrets.PRODUCTION_DEPLOY_SLACK_WEBHOOK_URL }}

  deploy:
    needs: slack-notify-start
    # ... production deploy steps ...

  slack-notify-complete:
    needs: deploy
    if: always() && !cancelled() && needs.deploy.result != 'skipped'
    uses: kgknutsson/github-workflows/.github/workflows/prod-deploy-slack-notify.yml@dev
    with:
      notification_phase: complete
      environment: prod
      service_name: my-service
      deployment_result: ${{ needs.deploy.result }}
    secrets:
      PRODUCTION_DEPLOY_SLACK_WEBHOOK_URL: ${{ secrets.PRODUCTION_DEPLOY_SLACK_WEBHOOK_URL }}
```

Use the same `environment` value as the GitHub `environment:` on the deploy job. Preview and staging jobs should use different environment names so this workflow stays silent.

Call this workflow with `@dev` until tag `v4` moves to a commit that contains this file. After that, pin the caller to the full commit SHA. The Slack action in this workflow is already pinned to commit `dcb1066f776dd043e64d0e8ba94ca15cc7e1875d` (`v4.0.0`). This job uses `ubuntu-latest` because it only posts a webhook.

## terraform-java-app-service.yml

Java GitOps deploy with optional `explicit_slot_swap` (inline health-gated swap) and `manage_deploy_slot_lifecycle`. Terraform apply uses the `terraform_runner` input. The default runner is `ubuntu-latest`. For ARM-based promotion without inline swap, use `azure-app-service-slot-promotion.yml` instead.

## java-testing-slot-deploy.yml

Testing-slot deploy workflow (dev branch). See workflow inputs for Flyway `flyway_source_ref`.

## Public content

Do not add organization names, product names, host names, tenant ids, or subscription ids to files.
Pass a caller-specific runner label from the caller repository.
A guard workflow scans each push.

Set repository variable `PUBLIC_REPO_DENYLIST` under **Settings → Secrets and variables → Actions → Variables**.
Use one term per line. Repo admins can view and edit this variable.
For local commits, set `DENYLIST_FILE` to a path outside the repository and run `.githooks/pre-commit`.
The guard tries the repository variable through the GitHub API when the token can read it. If the lookup fails, it uses the masked repository secret `PUBLIC_REPO_DENYLIST`. The Actions token often cannot read variables; keep the secret aligned with the variable after edits.

When you change the repository variable, refresh the masked secret from a clone of this repository:

`gh secret set PUBLIC_REPO_DENYLIST --body "$(gh variable get PUBLIC_REPO_DENYLIST)"`
