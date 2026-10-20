# github-workflows
Reusable GitHub Workflows (v4 development on branch `dev`).

## azure-app-service-slot-promotion.yml

Safe staging → production promotion with AutoSwap preflight, bounded health gates, ARM `slotsswap` with async/activity-log reconciliation, and fail-closed HTTP 409 / 04026 handling. See [docs/azure-app-service-slot-promotion.md](docs/azure-app-service-slot-promotion.md).

Pin `@dev` or `@v4` and set matching `scripts-ref`.

## azure-app-service-slot-swap-recovery-preflight.yml

Callable preflight for slot-swap recovery metadata (and optional production health URL). Cron and full reconciliation stay in the consumer repo. See [docs/slot-swap-guards-and-recovery.md](docs/slot-swap-guards-and-recovery.md) and [docs/examples/recover-slot-swap-cron-wrapper.yml](docs/examples/recover-slot-swap-cron-wrapper.yml).

## terraform-java-app-service.yml

Java GitOps deploy with optional `explicit_slot_swap` (inline health-gated swap) and `manage_deploy_slot_lifecycle`. Terraform apply runs on `azure-linux-runner` (ITCO-1546). For ARM-based promotion without inline swap, use `azure-app-service-slot-promotion.yml` instead.

## java-testing-slot-deploy.yml

Testing-slot deploy workflow (dev branch). See workflow inputs for Flyway `flyway_source_ref`.
