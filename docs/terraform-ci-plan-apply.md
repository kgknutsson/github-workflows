# Shared Terraform CI, plan, and apply

Three callable workflows. The caller repository owns `on:`, path filters, and branch rules. These workflows do not run on a schedule.

| Workflow | Credentials | Purpose |
| --- | --- | --- |
| `terraform-ci.yml` | No | `fmt`, `init -backend=false`, `validate` |
| `terraform-plan.yml` | OIDC | `init` with a backend file, then `plan` |
| `terraform-apply.yml` | OIDC | `plan`, then `apply` of that plan |

Call them from `dev` until tag `v4` moves to a commit that contains these files. After that, pin the full commit SHA.

Credentialed jobs use `azure-linux-runner` by default. Pass `runner: ubuntu-latest` only when state and providers are reachable from a GitHub-hosted runner.

## Secrets

The plan and apply workflows read these secrets:

- `AZURE_CLIENT_ID`
- `AZURE_SUBSCRIPTION_ID`
- `AZURE_TENANT_ID`

Map other secret names in the caller:

```yaml
secrets:
  AZURE_CLIENT_ID: ${{ secrets.CLIENT_ID }}
  AZURE_SUBSCRIPTION_ID: ${{ secrets.SUBSCRIPTION_ID }}
  AZURE_TENANT_ID: ${{ secrets.TENANT_ID }}
```

## Files

Empty `backend_config` uses `<environment>.tfbackend` inside `working_directory`.

Empty `var_file` uses `<environment>.tfvars` when that file exists. Set `pass_environment_var: true` to also pass `-var environment=<environment>`.

## Caller examples

```yaml
name: Terraform CI
on:
  pull_request:
    paths:
      - terraform/**
jobs:
  ci:
    uses: kgknutsson/github-workflows/.github/workflows/terraform-ci.yml@dev
    with:
      working_directory: terraform
```

```yaml
name: Terraform plan
on:
  workflow_dispatch:
    inputs:
      environment:
        required: true
        type: string
jobs:
  plan:
    uses: kgknutsson/github-workflows/.github/workflows/terraform-plan.yml@dev
    with:
      environment: ${{ inputs.environment }}
      working_directory: terraform
    secrets: inherit
```

```yaml
name: Terraform apply
on:
  workflow_dispatch:
    inputs:
      environment:
        required: true
        type: string
jobs:
  apply:
    uses: kgknutsson/github-workflows/.github/workflows/terraform-apply.yml@dev
    with:
      environment: ${{ inputs.environment }}
      working_directory: terraform
    secrets: inherit
```

`secrets: inherit` works when the caller already stores `AZURE_CLIENT_ID`, `AZURE_SUBSCRIPTION_ID`, and `AZURE_TENANT_ID`.

Plan and apply use the same concurrency group, `terraform-<environment>-<working_directory>`, and they do not cancel an in-progress run.

Apply retries the plan up to 10 times when the state lock is busy, then applies that saved plan.

Set `upload_outputs: true` on apply to upload `terraform output -json` as artifact `terraform-output`.

## What stays separate

`terraform-java-app-service.yml` still deploys a Java app. It uses `gitops-apply-terraform` and can swap slots. Do not replace that workflow with these three.

ServiceLayer Terraform checks out a second repository for modules before `init`. These workflows check out only the caller repository. Keep the ServiceLayer shared Terraform workflows for that checkout.
