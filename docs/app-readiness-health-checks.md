# App readiness health checks (host vs downstream)

Guidance for **application** `/api/health` (or `/actuator/health`) used by Azure App Service and by slot promotion workflows (`health-check-path`, `WEBSITE_SWAP_WARMUP_PING_PATH`, Terraform `health_check_path`).

Related: [azure-app-service-slot-promotion.md](azure-app-service-slot-promotion.md), [slot-swap-guards-and-recovery.md](slot-swap-guards-and-recovery.md).

## What CI and Azure expect

| Layer | Checks | Typical pass |
|-------|--------|--------------|
| **GitHub slot gate** | HTTP GET to `{staging-host}{health-check-path}` | **200** |
| **Azure slot swap** | Platform ping on `healthCheckPath` / swap warmup settings | **200** (configured statuses) |
| **Application readiness** | ASP.NET `MapHealthChecks` (or equivalent) | **JSON** body with `status` |

A **503 HTML page** (“Service Unavailable” with no JSON) means the **worker is not serving the app**. Promotion must fail. This is not a “dependency degraded” response from your health middleware.

## Host readiness vs downstream probes

**Do**

- Use readiness on the **deployed host** (process up, config loaded, **in-scope** dependencies the app owns).
- Example: Identity module checks **Commercetools** and **Redis** because those are direct backends for that API.
- Keep **liveness** separate (`/api/health/live` with no dependency checks) when you split probes.

**Do not**

- Call **Service Layer / APIM** from readiness with an unauthenticated **HEAD** to the API **base URL** (no real health route). Common outcomes:
  - **404** treated as healthy while App Insights marks the outbound call failed.
  - Noise on every Azure health poll.
  - False confidence during slot swap (host “healthy”, SL still broken for real traffic).

Real SL availability belongs in **SL/APIM monitoring**, authenticated smoke tests, or an **agreed** SL health endpoint — not a synthetic HEAD on the Refit root.

## ecom-cv-site-backend pattern (2026 health hardening)

| Module | Readiness dependencies |
|--------|-------------------------|
| Order, Price, Stock | **Host only** after removing the SL probe (no SL probe) |
| Identity | Commercetools + Redis |

Local composite: `ecom-cv-site-backend/.github/actions/azure-slot-swap` (same curl + `az webapp deployment slot swap` pattern as reusable promotion scripts).

## When promotion fails but production still looks fine

1. **Package deploys to staging**; **swap never runs** if staging health fails.
2. **Production** keeps the **previous** build until swap succeeds.
3. Fix **staging** (startup crash, stopped slot, missing slot settings, platform 503) — not by weakening health rules on production.

Optional: `manage_deploy_slot_lifecycle: true` on reusable promotion starts the staging slot before deploy/health when your plan uses stop-after-promote idle patterns.

## Verification after a successful swap

1. `GET` production `{health-path}` → **200** and expected JSON entries (no removed checks reappearing).
2. Application Insights: no recurring **failed** HTTP dependencies tied to health polls for removed probes.
3. Azure portal: staging and production slots **Running** when you expect traffic.

## References

- ecom-cv-site-backend PR #365 — remove misleading SL readiness probe.
- Cookbook mirror: `GitHub-Workflow-Templates/docs/APP_READINESS_HEALTH_CHECKS.md`.
