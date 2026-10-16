# github-workflows
Reusable GitHub Workflows

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
    uses: kgknutsson/github-workflows/.github/workflows/prod-deploy-slack-notify.yml@v4
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
    uses: kgknutsson/github-workflows/.github/workflows/prod-deploy-slack-notify.yml@v4
    with:
      notification_phase: complete
      environment: prod
      service_name: my-service
      deployment_result: ${{ needs.deploy.result }}
    secrets:
      PRODUCTION_DEPLOY_SLACK_WEBHOOK_URL: ${{ secrets.PRODUCTION_DEPLOY_SLACK_WEBHOOK_URL }}
```

Use the same `environment` value as the GitHub `environment:` on the deploy job. Preview and staging jobs should use different environment names so this workflow stays silent.

## terraform-java-app-service.yml

Optional input `manage_deploy_slot_lifecycle` (default `false`): when `true` with `explicit_slot_swap`, starts the deploy `slot-name` before package deploy and stops it after production health checks pass, to free App Service plan memory between releases.

