# SPA App Service pull request preview

Three callable workflows. The caller repository owns `on:`, path filters, and the schedule. These workflows do not apply Terraform and they do not swap a slot to production.

| Workflow | Purpose |
| --- | --- |
| `spa-app-service-pr-preview.yml` | Create the preview slot when it is missing, build, zip-deploy, return the hostname |
| `spa-app-service-pr-preview-cleanup.yml` | Delete one preview slot and the preview comment |
| `spa-app-service-pr-preview-orphan-cleanup.yml` | Delete `pr-*` slots whose pull request is not open |

A deployment slot uses the parent web app's App Service plan. Pass the web app name and the resource group as inputs. Do not read them from Terraform output.

## Secrets

Map the caller secret names at the call site:

```yaml
secrets:
  AZURE_CLIENT_ID: ${{ secrets.CLIENT_ID }}
  AZURE_SUBSCRIPTION_ID: ${{ secrets.SUBSCRIPTION_ID }}
  AZURE_TENANT_ID: ${{ secrets.TENANT_ID }}
```

`secrets: inherit` does not rename those secrets.

The preview job also needs `contents: read` and `id-token: write`. Cleanup and orphan cleanup also need `issues: write` and `pull-requests: read`.

## Build variables

`build_env_json` is a JSON object of public build-time variables. Do not put secrets in it. The caller can pass Entra values from GitHub environment variables.

`slot_name` must not be `production` or `staging`. A caller passes `pr-<number>`.

Empty `health_path` skips the HTTP probe. The default path is `/health`. The probe requires HTTP 200 from that path and it does not follow redirects.

Set `disable_easy_auth: true` when the app signs in without Easy Auth.

Set `entra_app_id` on cleanup only when redirect URIs for `pr-<number>` must be removed. Leave it empty to skip that step.

## Caller sketch

```yaml
jobs:
  preview:
    permissions:
      contents: read
      id-token: write
    uses: kgknutsson/github-workflows/.github/workflows/spa-app-service-pr-preview.yml@dev
    with:
      environment: dev
      webapp_name: ${{ vars.WEBAPP_NAME }}
      resource_group: ${{ vars.RESOURCE_GROUP }}
      slot_name: pr-${{ github.event.pull_request.number }}
      node_version: "24"
      build_command: yarn build
      health_path: /health
      build_env_json: '{"VITE_AUTH_MODE":"webapp"}'
    secrets:
      AZURE_CLIENT_ID: ${{ secrets.CLIENT_ID }}
      AZURE_SUBSCRIPTION_ID: ${{ secrets.SUBSCRIPTION_ID }}
      AZURE_TENANT_ID: ${{ secrets.TENANT_ID }}

  comment:
    needs: preview
    runs-on: ubuntu-latest
    permissions:
      pull-requests: write
    steps:
      - name: Post the preview URL
        env:
          SLOT_URL: ${{ needs.preview.outputs.slot_url }}
        run: echo "Post $SLOT_URL on the pull request."
```

Call the workflows with `@dev` until this commit is on `dev`. After that, pin the full commit SHA. Tag `v4` does not move with this pull request.
