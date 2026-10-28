# Slot swap guards, recovery, and cron ownership

This document explains how **promotion**, **inline Terraform swap**, **recovery metadata**, and **scheduled cron** fit together on the v4 (`dev`) line of `kgknutsson/github-workflows`.

## Three promotion patterns

| Pattern | When to use | Where swap runs |
|--------|-------------|-----------------|
| **Promote only** | Staging already has the build | Reusable `azure-app-service-slot-promotion.yml` |
| **Deploy package + promote** | One workflow builds, uploads artifact, then promotes | Same reusable workflow (`package-artifact-name`) |
| **Inline Terraform / Java deploy** | Existing `terraform-java-app-service.yml` with `explicit_slot_swap: true` | `az webapp deployment slot swap` inside deploy job |

The promotion reusable uses ARM `slotsswap` with activity-log correlation. The Java workflow keeps health-gated `az webapp deployment slot swap` for callers that already use that contract.

Do **not** enable Azure AutoSwap on the staging slot when GitHub Actions owns promotion. The promotion workflow fails preflight if AutoSwap is on.

## Recovery metadata (app repo)

Interrupted swaps and deployment markers use App Service application settings:

| Setting | Role |
|---------|------|
| `SLOT_SWAP_RECOVERY_STATE` | Example setting name. Values are `healthy`, `swap-pending`, `rollback-pending`, or empty. |
| `SLOT_SWAP_RUN_ID` | Example setting name. The value is a `run-<id>-<attempt>` marker on production or staging. |

**Full reconciliation** (queue, lease, rollback, GitHub run correlation) is **application-specific**. It depends on your deployment workflow name, paths, and scripts (see `ecom-cv-site-frontend` `recover-slot-swap.yml`).

This repo provides:

- **Reusable preflight** — `azure-app-service-slot-swap-recovery-preflight.yml` (metadata + optional production health URL).
- **Guard script** — `.github/scripts/azure-app-service-slot-swap-guards.sh` (`scheduled-preflight`).
- **GitHub run correlation** — `.github/scripts/azure-app-service-slot-swap-github-run.sh` (`load_run_metadata`, orphan detection when the Actions run returns HTTP 404).
- **Caller cron wrapper template** — [docs/examples/recover-slot-swap-cron-wrapper.yml](examples/recover-slot-swap-cron-wrapper.yml).

**Orphan run markers:** Recovery metadata stores `run-<id>-<attempt>`. If that run was deleted, purged, or never existed in the consumer repo, reconciliation must not fail permanently when production health is good. Source `azure-app-service-slot-swap-github-run.sh` (or mirror the logic in your app script), validate the deployment workflow **path** (not the display `run-name`), and clear stale metadata after a successful health check. Reference: `ecom-cv-site-frontend` `slot-swap-recovery.sh` (`reconcile_orphan_run_metadata`).

**Sourcing `azure-app-service-slot-swap-github-run.sh`:** In the consumer recovery job set `permissions.actions: read`, `API_TOKEN: ${{ github.token }}`, and `GITHUB_REPOSITORY` (default in Actions). Optionally set `SLOT_SWAP_DEPLOYMENT_WORKFLOW_PATH` when the deploy workflow file is not `.github/workflows/deployment.yml`. Pin the same ref in sparse checkout as other reusable workflow `scripts-ref` inputs. Orphan cleanup (`set_healthy`, health probes) stays in the app repo; this script only loads run metadata and sets `SLOT_SWAP_RUN_METADATA_ORPHAN` on HTTP 404.

**v4 promotion without recovery app settings:** `azure-app-service-slot-promotion.yml` uses ARM slot swap and does not write slot-swap recovery state or run-id app settings. Apps on that path avoid this metadata class; keep recovery cron only while legacy deployment workflows still use those markers.

## Cron ownership (GitHub Actions limitation)

`schedule` triggers run only from workflow YAML in the **consumer repository**. A pure `workflow_call` reusable **cannot** define cron for callers.

Design:

1. Put `on.schedule` and `on.workflow_dispatch` in the **app repo** wrapper workflow.
2. Call `kgknutsson/github-workflows/.../azure-app-service-slot-swap-recovery-preflight.yml@dev` for each environment (or matrix).
3. Run your app-specific **recover** job only when preflight outputs `recovery-needed: true`.
4. Use `workflow_dispatch` for urgent recovery outside the schedule.

GitHub runs scheduled workflows from the **default branch** only. Document that in the consumer repo README.

## Default office-hours cron (UTC)

Weekdays every two hours during approximate Stockholm office hours (08:00–18:00 at UTC+2):

```yaml
on:
  schedule:
    - cron: '0 6,8,10,12,14,16 * * 1-5'
  workflow_dispatch:
```

Adjust crons in the **caller repo** for DST or different regions. Reusable workflows do not accept cron inputs; override only in consumer YAML.

## `always()` and `!cancelled()` pattern

Scheduled recovery wrappers should:

- Use `if: always() && !cancelled()` on aggregate/plan jobs after matrix preflight.
- Avoid treating `cancelled()` matrix legs as success when planning recoveries.

See the frontend `recover-slot-swap.yml` reference and [examples/recover-slot-swap-cron-wrapper.yml](examples/recover-slot-swap-cron-wrapper.yml).

## Pinning refs

Pin `@dev` or `@v4` (when tagged) on reusable workflows **and** pass the same ref in `scripts-ref` until a release bundles workflow + script together.

## Related docs

- [azure-app-service-slot-promotion.md](azure-app-service-slot-promotion.md) — promotion contract and examples.
- [app-readiness-health-checks.md](app-readiness-health-checks.md) — host readiness vs downstream API probes (ecom cv backend learnings).

## Slack production notify (optional)

Production deploy Slack notification is `prod-deploy-slack-notify.yml`. It is independent of slot promotion.
