# Azure App Service slot promotion (reusable workflow)

Reusable workflow: `.github/workflows/azure-app-service-slot-promotion.yml`

Promotion logic lives in `.github/scripts/azure-app-service-slot-promotion.sh`.

For recovery metadata, cron wrappers, and guard patterns see [slot-swap-guards-and-recovery.md](slot-swap-guards-and-recovery.md).

## Caller contract

| Requirement | Detail |
|-------------|--------|
| GitHub Environment | Pass required input `environment` (for example `prod`). The reusable job binds it for approval gates. OIDC secrets `CLIENT_ID`, `TENANT_ID`, `SUBSCRIPTION_ID` must exist on that environment. |
| Azure RBAC | Identity can deploy to the staging slot and run `Microsoft.Web/sites/slots/slotsswap/action`. |
| Terraform | `auto_swap_slot_name` must be **disabled** on the staging slot. AutoSwap drift fails preflight. |
| Runner | `runner` defaults to `ubuntu-latest`. A private health endpoint needs a label for a runner that can reach the app. |
| Health | Staging health must pass before ARM swap. Production health runs after swap. Configure `health-check-url` or `health-check-path` / App Service `healthCheckPath`. |
| Pinning | Pin the reusable workflow ref **and** pass the same ref in `scripts-ref` (for example `dev` or `v4`). |
| Slot lifecycle | Optional `manage_deploy_slot_lifecycle: true` starts the staging slot before deploy or health checks and stops it after production health passes. |
| Warmup settings | Optional. Set `swap-warmup-ping-path` to read warmup app settings on both slots and fail before swap on mismatch. Empty inputs keep the previous behavior. |


## Swap warmup settings

Azure slot swap pings every worker. The default ping path is `/`. A path that queries a database can miss the ping deadline. The platform error is `the 'staging' slot did not respond to http ping`.

Set these application settings in Terraform or equivalent platform config. Make each setting sticky on the production slot and on the staging slot. Do not set them with `az webapp config appsettings set` during deploy. That command restarts the app and makes the swap slower.

| Setting | Example | Purpose |
|---------|---------|---------|
| `WEBSITE_SWAP_WARMUP_PING_PATH` | `/api/health/live` | Path the platform pings during swap. |
| `WEBSITE_SWAP_WARMUP_PING_STATUSES` | `200` | HTTP statuses that count as a successful ping. |
| `WEBSITE_WARMUP_PATH` | `/api/health/live` | Path a worker requests while it warms up. |

`/api/health/live` is an example of process liveness. It does not query the database. Callers choose their own fast path. Do not point the ping at a readiness path that queries the database.

Allow the App Service service tag on both slots. The IP restriction uses `service_tag` `AppService` and action Allow. Slot swap can leave each slot with the other slot's rules. A default deny without this allow rule blocks the platform ping.

Set the App Service health check path to the liveness path. A database failure must not evict workers. A public edge probe, such as Front Door, can stay on the readiness path. Set the worker count and the health check path in platform config. This workflow does not write them.

| Input | Default | Behavior |
|-------|---------|----------|
| `swap-warmup-ping-path` | empty | When set, read `WEBSITE_SWAP_WARMUP_PING_PATH` on the production slot and the staging slot. Fail before swap when the value does not match. When empty, skip the check. |
| `swap-warmup-ping-statuses` | empty | Expected `WEBSITE_SWAP_WARMUP_PING_STATUSES` when the ping path input is set. Empty means `200`. |
| `warmup-path` | empty | When set together with the ping path, also require `WEBSITE_WARMUP_PATH` on both slots. When empty, this workflow does not read that setting. |

The check uses `az webapp config appsettings list` only. It does not write application settings and it does not restart the app.

Pass the same ref in `scripts-ref` as the reusable workflow ref.

```yaml
    with:
      swap-warmup-ping-path: /api/health/live
      warmup-path: /api/health/live
      scripts-ref: dev
```

Omit `swap-warmup-ping-statuses` to expect `200`. `azure-webapp-zip-deploy.yml` does not swap slots and does not read these settings. The inline swap in `terraform-java-app-service.yml` does not read these settings. Set the platform config for those paths in the caller repository.

## Example caller (promote only)

Use when the caller already deployed to the staging slot:

```yaml
jobs:
  promote:
    needs: build
    permissions:
      id-token: write
      contents: read
    uses: kgknutsson/github-workflows/.github/workflows/azure-app-service-slot-promotion.yml@dev
    with:
      environment: prod
      webapp-name: ${{ vars.WEBAPP_NAME }}
      resource-group: ${{ vars.RESOURCE_GROUP }}
      health-check-path: /api/health
      scripts-ref: dev
    secrets:
      CLIENT_ID: ${{ secrets.CLIENT_ID }}
      TENANT_ID: ${{ secrets.TENANT_ID }}
      SUBSCRIPTION_ID: ${{ secrets.SUBSCRIPTION_ID }}
```

## Example caller (deploy package + promote)

Build and upload the package in one job. The promotion job downloads the artifact (fresh runner).

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: ./mvnw -DskipTests package
      - uses: actions/upload-artifact@v4
        with:
          name: app-package
          path: target/*.jar

  release:
    needs: build
    permissions:
      id-token: write
      contents: read
    uses: kgknutsson/github-workflows/.github/workflows/azure-app-service-slot-promotion.yml@dev
    with:
      environment: prod
      webapp-name: ${{ vars.WEBAPP_NAME }}
      resource-group: ${{ vars.RESOURCE_GROUP }}
      package-artifact-name: app-package
      package-artifact-filename: myapp.jar
      health-check-path: /actuator/health
      promotion-max-wait-seconds: 900
      smoke-test-url: https://example.com/api/health
      scripts-ref: dev
    secrets: inherit
```

## Failure behavior

- **409 / 04026**: Fail closed. No retry swap. Do not infer success from a second swap attempt.
- **Production health failure after swap**: Runs `rollback-swap` (CLI swap staging back to production) when ARM promote succeeded but production health failed.
- **Client timeout on ARM POST**: Reconcile via async polling and activity-log correlation only. No blind second swap.
- **Deadline**: `promotion-max-wait-seconds` caps the whole promotion window. Each HTTP call uses the remaining time.
- **`manage_deploy_slot_lifecycle`**: Stops the staging slot when the job finishes (`always()`), including failed deploy or health checks.
- **Warmup settings**: When `swap-warmup-ping-path` is set, a mismatch fails the job before the ARM swap. The job does not write the settings.

## Migration note

This workflow does not switch production callers by itself. Migrate one non-production environment first.
