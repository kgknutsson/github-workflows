# Slot swap guards, recovery, and cron ownership

This document explains how **promotion**, **inline Terraform swap**, **recovery metadata**, and **scheduled cron** fit together on the v4 (`dev`) line of `kgknutsson/github-workflows`.

## Three promotion patterns

| Pattern | When to use | Where swap runs |
|--------|-------------|-----------------|
| **Promote only** | Staging already has the build | Reusable `azure-app-service-slot-promotion.yml` |
| **Deploy package + promote** | One workflow builds, uploads artifact, then promotes | Same reusable workflow (`package-artifact-name`) |
| **Java GitOps deploy** | Existing `terraform-java-app-service.yml` with `explicit_slot_swap: true` | Same ARM script as the promotion workflow (`promote`, then `production-health`) |

The promotion workflow and the Java explicit slot swap both call `.github/scripts/azure-app-service-slot-promotion.sh`. Rollback after a confirmed swap still uses one CLI swap. A second swap is not used to guess whether a timed-out request finished.

Do **not** enable Azure AutoSwap on the staging slot when GitHub Actions owns promotion. The promotion workflow fails preflight if AutoSwap is on.

Stop the staging slot only after production health passes. A failed promotion leaves the slot running so the failed build can be inspected. A weekly idle-stop caller turns that slot off later. See [examples/staging-slot-idle-stop-cron.yml](examples/staging-slot-idle-stop-cron.yml). Give that caller the deploy concurrency group and leave `cancel-in-progress` false. A sweep that sets `cancel-in-progress` to true can cancel a deploy. Do not use that setting for the staging idle stop.

## Recovery metadata (app repo)

Interrupted swaps and deployment markers use App Service settings (KGK convention):

| Setting | Role |
|---------|------|
| `KGK_SLOT_SWAP_RECOVERY_STATE` | `healthy`, `swap-pending`, `rollback-pending`, or empty |
| `KGK_SLOT_SWAP_RUN_ID` | `run-<id>-<attempt>` marker on production or staging |

**Full reconciliation** (queue, lease, rollback, GitHub run correlation) is **application-specific**. It depends on your deployment workflow name, paths, and scripts (see `ecom-cv-site-frontend` `recover-slot-swap.yml`).

This repo provides:

- **Reusable preflight** — `azure-app-service-slot-swap-recovery-preflight.yml` (metadata + optional production health URL).
- **Guard script** — `.github/scripts/azure-app-service-slot-swap-guards.sh` (`scheduled-preflight`).
- **Caller cron wrapper template** — [docs/examples/recover-slot-swap-cron-wrapper.yml](examples/recover-slot-swap-cron-wrapper.yml).

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

## Slack production notify (optional)

Production deploy Slack notification lives on PR #13 (`prod-deploy-slack-notify.yml`, branch `ITCO-1174-feat/prod-deploy-slack-notify`). It is independent of slot promotion; merge or pin separately when ready.
