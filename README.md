# github-workflows
Reusable GitHub Workflows

## Terraform CI, plan, and apply

`terraform-ci.yml`, `terraform-plan.yml`, and `terraform-apply.yml` are callable workflows. The caller owns triggers. See `docs/terraform-ci-plan-apply.md`.

## terraform-java-app-service.yml

Optional input `manage_deploy_slot_lifecycle` (default `false`): when `true` with `explicit_slot_swap`, starts the deploy `slot-name` before package deploy and stops it after production health checks pass, to free App Service plan memory between releases.

