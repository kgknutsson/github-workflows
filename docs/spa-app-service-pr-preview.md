# SPA App Service pull request preview

Three callable workflows. The caller repository owns `on:`, path filters, and the schedule. These workflows do not apply Terraform and they do not swap a slot to production.

| Workflow | Purpose |
| --- | --- |
| `spa-app-service-pr-preview.yml` | Provision slot, optional caller prepare script, build, SCM wait, zip-deploy retries, HTTP verify |
| `spa-app-service-pr-preview-cleanup.yml` | Delete one preview slot and the preview comment |
| `spa-app-service-pr-preview-orphan-cleanup.yml` | Delete `pr-*` slots whose pull request is not open |

## Deploy job split

`spa-app-service-pr-preview.yml` uses two jobs:

1. **provision-slot** — create the slot when missing, disable auto-swap, optional public network
2. **deploy-to-slot** — checkout caller repo, optional caller prepare script, SCM wait (when the slot was new), build, zip-deploy with retries, HTTP verify, failure summary

## Hardening

| Step | Behavior |
| --- | --- |
| SCM wait | Polls the slot SCM site until HTTP is not 503 (new slots only by default) |
| Zip deploy | Retries transient Kudu 503 errors with backoff |
| Verify | Probes `health_path`; optional Easy Auth redirect acceptance |
| Failure summary | Writes a step summary with category: `platform_transient`, `platform_config`, `build`, `app_runtime`, or `workflow` |

Call the workflow with `@dev` until the commit is on `dev`. After merge, pin a commit SHA. Tag `v4` does not move with every pull request.

## Secrets

Map caller secret names at the call site:

```yaml
secrets:
  AZURE_CLIENT_ID: ${{ secrets.CLIENT_ID }}
  AZURE_SUBSCRIPTION_ID: ${{ secrets.SUBSCRIPTION_ID }}
  AZURE_TENANT_ID: ${{ secrets.TENANT_ID }}
  PR_PREVIEW_AUTH_CLIENT_ID: ${{ secrets.PR_PREVIEW_AUTH_CLIENT_ID }}
```

The preview jobs need `contents: read` and `id-token: write`.

## Caller prepare script

Use `caller_prepare_script` for repository-specific slot hardening (IP rules, Easy Auth, private SCM). Pass public values through `caller_prepare_env_json`.

## Caller sketch (SPA matrix)

```yaml
deploy-webapp-apps:
  needs: affected
  strategy:
    fail-fast: false
    matrix:
      name: ${{ fromJSON(needs.affected.outputs.spa_apps) }}
  permissions:
    contents: read
    id-token: write
  uses: kgknutsson/github-workflows/.github/workflows/spa-app-service-pr-preview.yml@dev # pin a commit after merge
  with:
    environment: dev
    webapp_name: app-example-${{ matrix.name }}frontend-dev
    resource_group: rg-example-frontend-dev
    slot_name: pr-${{ github.event.pull_request.number }}
    node_version: "22"
    install_command: yarn install --frozen-lockfile
    build_command: yarn nx build ${{ matrix.name }} --mode=development
    output_directory: dist/apps/${{ matrix.name }}
    health_path: /health
    accept_auth_redirect: true
    caller_prepare_script: .github/scripts/pr-preview-spa-slot-prepare.sh
    caller_prepare_env_json: ${{ format('{{"APP_SLUG":"{0}","PR_NUMBER":"{1}"}}', matrix.name, github.event.pull_request.number) }}
    runner: ubuntu-latest
    scripts_ref: dev
  secrets:
    AZURE_CLIENT_ID: ${{ secrets.CLIENT_ID }}
    AZURE_SUBSCRIPTION_ID: ${{ secrets.SUBSCRIPTION_ID }}
    AZURE_TENANT_ID: ${{ secrets.TENANT_ID }}
    PR_PREVIEW_AUTH_CLIENT_ID: ${{ secrets.PR_PREVIEW_AUTH_CLIENT_ID }}
```

The caller still owns the pull request comment job. Use `spa-app-service-pr-preview-cleanup.yml` and `spa-app-service-pr-preview-orphan-cleanup.yml` for slot teardown. Optional `caller_pre_delete_script` runs before slot delete (for example private SCM cleanup).
