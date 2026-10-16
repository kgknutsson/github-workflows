# github-workflows
Reusable GitHub Workflows

## azure-app-service-slot-promotion.yml

Safe staging → production promotion with AutoSwap preflight, bounded health gates, ARM `slotsswap` with async/activity-log reconciliation, and fail-closed HTTP 409 / 04026 handling. See [docs/azure-app-service-slot-promotion.md](docs/azure-app-service-slot-promotion.md).

## terraform-java-app-service.yml

Optional input `manage_deploy_slot_lifecycle` (default `false`): when `true` with `explicit_slot_swap`, starts the deploy `slot-name` before package deploy and stops it after production health checks pass, to free App Service plan memory between releases.

