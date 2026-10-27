# Azure Web App zip deploy (callable)

Use `azure-webapp-zip-deploy.yml` for **direct** zip deploy to a slot (typically `production` on dev).

Pair it with `azure-app-service-slot-promotion.yml` for production releases:

1. Build and upload a zip artifact in the caller.
2. Call promotion with `package-artifact-name`, `health-check-path`, and optional `manage_deploy_slot_lifecycle: true`.

Pin the caller and `scripts-ref` on promotion to the same ref (`@v4` or `@dev`).

## Example (SPA production)

```yaml
jobs:
  promote-fleet:
    needs: build
    permissions:
      id-token: write
      contents: read
    uses: kgknutsson/github-workflows/.github/workflows/azure-app-service-slot-promotion.yml@v4
    with:
      environment: webapp-prod
      webapp-name: app-example-frontend-prod
      resource-group: rg-example-frontend-prod
      package-artifact-name: webapp-fleet
      health-check-path: /health
      manage_deploy_slot_lifecycle: true
      scripts-ref: v4
    secrets: inherit
```
