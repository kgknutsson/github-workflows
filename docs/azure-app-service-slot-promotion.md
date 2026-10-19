# Azure App Service slot promotion (reusable workflow)

Reusable workflow: `.github/workflows/azure-app-service-slot-promotion.yml`

Promotion logic lives in `.github/scripts/azure-app-service-slot-promotion.sh` (ITCO-1417 / monorepo PR #1145 reference behavior).

## Caller contract

| Requirement | Detail |
|-------------|--------|
| GitHub Environment | Pass required input `environment` (for example `prod`). The reusable job binds it for approval gates. OIDC secrets `CLIENT_ID`, `TENANT_ID`, `SUBSCRIPTION_ID` must exist on that environment. |
| Azure RBAC | Identity can deploy to the staging slot and run `Microsoft.Web/sites/slots/slotsswap/action`. |
| Terraform | `auto_swap_slot_name` must be **disabled** on the staging slot. AutoSwap drift fails preflight. |
| Runner | Default `azure-linux-runner` when health endpoints are behind access restrictions. Use `ubuntu-latest` only when staging and production URLs are reachable from GitHub-hosted runners. |
| Health | Staging health must pass before ARM swap. Production health runs after swap. Configure `health-check-url` or `health-check-path` / App Service `healthCheckPath`. |
| Pinning | Pin the reusable workflow ref **and** pass the same ref in `scripts-ref` until a release tag bundles both files. |

## Example caller (promote only)

Use when the caller already deployed to the staging slot:

```yaml
jobs:
  promote:
    needs: build
    uses: kgknutsson/github-workflows/.github/workflows/azure-app-service-slot-promotion.yml@main
    with:
      environment: prod
      webapp-name: ${{ vars.WEBAPP_NAME }}
      resource-group: ${{ vars.RESOURCE_GROUP }}
      health-check-path: /api/health
      scripts-ref: main
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
    uses: kgknutsson/github-workflows/.github/workflows/azure-app-service-slot-promotion.yml@main
    with:
      environment: prod
      webapp-name: ${{ vars.WEBAPP_NAME }}
      resource-group: ${{ vars.RESOURCE_GROUP }}
      package-artifact-name: app-package
      package-artifact-filename: myapp.jar
      health-check-path: /actuator/health
      promotion-max-wait-seconds: 900
      smoke-test-url: https://example.com/api/health
      scripts-ref: main
    secrets: inherit
```

## Failure behavior

- **409 / 04026**: Fail closed. No retry swap and no rollback swap from this workflow.
- **Client timeout on ARM POST**: Reconcile via async polling and activity-log correlation only. No blind second swap.
- **Deadline**: `promotion-max-wait-seconds` caps the whole promotion window. Each HTTP call uses the remaining time.

## Migration note

This ticket does **not** switch production consumers (for example Autoexperten). After merge, migrate one dev environment first, then document prod approval in the consumer repo.
