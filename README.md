# github-workflows
Reusable GitHub Workflows (v4 development on branch `dev`).

## azure-app-service-slot-promotion.yml

Safe staging → production promotion with AutoSwap preflight, bounded health gates, ARM `slotsswap` with async/activity-log reconciliation, and fail-closed HTTP 409 / 04026 handling. See [docs/azure-app-service-slot-promotion.md](docs/azure-app-service-slot-promotion.md).

Pin `@dev` or `@v4` and set matching `scripts-ref`.

## azure-app-service-slot-swap-recovery-preflight.yml

Callable preflight for slot-swap recovery metadata (and optional production health URL). Cron and full reconciliation stay in the consumer repo. See [docs/slot-swap-guards-and-recovery.md](docs/slot-swap-guards-and-recovery.md) and [docs/examples/recover-slot-swap-cron-wrapper.yml](docs/examples/recover-slot-swap-cron-wrapper.yml).

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

Java GitOps deploy with optional `explicit_slot_swap` (inline health-gated swap) and `manage_deploy_slot_lifecycle`. Terraform apply runs on `azure-linux-runner` (ITCO-1546). For ARM-based promotion without inline swap, use `azure-app-service-slot-promotion.yml` instead.

## java-testing-slot-deploy.yml

Testing-slot deploy workflow (dev branch). See workflow inputs for Flyway `flyway_source_ref`.
