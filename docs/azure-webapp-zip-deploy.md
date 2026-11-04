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

## Runner

`runner` is the runner label. The default is `ubuntu-latest`.

`runner-group` is optional. When you set it, the deploy job runs in that group and uses the `runner` label.

A private endpoint needs both inputs. Set `runner-group` to the group name and `runner` to a label in that group. Leave `runner-group` empty to keep label-only selection.

```yaml
    runner: self-hosted-linux
    runner-group: private-runners
```

The build job stays in the caller. It can use `ubuntu-latest`. Only the deploy job uses these inputs.
