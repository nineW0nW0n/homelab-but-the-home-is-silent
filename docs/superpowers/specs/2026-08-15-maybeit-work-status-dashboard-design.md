# `maybeit.work` status dashboard, design

> **Superseded in three places (2026-08-16).** This is a point-in-time
> design record; it is annotated rather than rewritten so the reasoning
> stays readable. What shipped differs here:
>
> - **No Cron Trigger.** Anything in a request chain rooted at a Cron
>   Trigger gets a 403 from Access when calling this account's own
>   Access-protected apps, even with a working service token. The Worker
>   polls on request instead, cached for 30s. Sections 69, 124-125 and
>   136 below describe the abandoned design, see
>   `worker/status/CLAUDE.md`'s failure log for what was tried.
> - **vps02 is not idle.** Line 34's "no workload" was true when written;
>   it now runs Netdata, `cloudflared` and a Dokploy-installed Traefik.
> - **`/debug` is gated.** It requires an `x-debug-key` header matched
>   against a Worker secret and 404s otherwise.

> **Implementation update (during execution, 2026-08-15):** Netdata is
> deployed as a **Docker container via `stacks/<node>/` + `deploy.yml`**
> (GitOps, matching this repo's stated deploy model), not the ad-hoc SSH
> provisioning script this doc originally described below. Root cause:
> the only SSH access available is the `deploy` CI user (no sudo, rail
> 6), a native install needs root, which isn't reachable. `deploy` is
> already in the `docker` group, so a container fits the access that
> actually exists, and folds Netdata into the same rollout as
> `cloudflared` instead of a separate manual step. Resource overhead is
> effectively identical to a native install (same process; container
> packaging adds a few MB, see the implementation plan for sourcing).
> The retention/tuning/alerting goals below are unchanged, only the
> delivery mechanism. The implementation plan is the current source of
> truth for exact files/steps.

## Goal

A page at the apex domain `maybeit.work` showing live health of the
homelab: red/green status per node (vps00, vps01, vps02) and Dokploy
itself, plus CPU/mem/disk utilization (0-100%) per node. Alerts on
threshold breach go to Telegram, independent of the page.

This is **not** a marketing/portfolio landing page, scope changed
during brainstorming once the actual intent (an ops status view)
surfaced.

## Current state (verified live, 2026-08-15)

- No landing/status site provisioned anywhere. `docker ps` on all
  three nodes shows only: vps00 (Dokploy control plane + its tunnel),
  vps01 (`booking` stack + its tunnel), vps02 (bare Dokploy Remote
  Server agent, no workload). Confirmed via SSH, not assumed.
- Dokploy has built-in monitoring (CPU/mem/disk/network via Docker
  stats, port 4500) but **only for its own host (vps00)**, remote
  server monitoring is an open, unshipped upstream feature request
  ([Dokploy#4420](https://github.com/Dokploy/dokploy/issues/4420)).
  Not usable alone for a 3-node view.
- No mail server exists anywhere in this repo. Not building one for
  alerts, Telegram is the notification channel (see below).

## Deviation from project defaults

Root `CLAUDE.md`'s global default is GitHub + Dokploy for all
deployment. This project explicitly uses **Cloudflare Workers**
instead, for this piece only, no VPS/Dokploy involvement in serving
the page itself. Decided in brainstorming: static/dynamic hosting on
Cloudflare's free tier (verified against
[Workers pricing](https://developers.cloudflare.com/workers/platform/pricing/)
and [Pages limits](https://developers.cloudflare.com/pages/platform/limits/))
is strictly simpler than adding a 4th piece of VPS-hosted
infrastructure for something with no server-side logic of its own
beyond polling and rendering.

## Architecture

```
 vps00/01/02 (Netdata agent, port 19999, localhost-bound)
        │  cloudflared tunnel, new Public Hostname per node,
        │  reusing that node's existing tunnel token (rail 2:
        │  one token per node, not one hostname per token)
        ▼
 Cloudflare Access (service token gates the route; a second
 policy allows your own email/OTP for manual dashboard access)
        │
        ▼
 Cloudflare Worker (bound to apex maybeit.work)
   - Cron Trigger, every 5 min: polls each node's Netdata API
     (cpu/mem/disk %) + a plain reachability check against
     dokploy.maybeit.work (already public, no new exposure) →
     writes one JSON snapshot to Workers KV.
   - fetch handler (page views): reads latest KV snapshot,
     renders red/green lights + utilization bars. No live
     per-view polling of the VPSes, page load stays fast and
     independent of a node being slow/down.
        │
        ▼
 Netdata's own health/alarm engine (independent of the Worker)
   → Telegram bot, per node, on threshold breach.
```

## Data collection, Netdata, tuned

Barebones profile on all 3 nodes, not defaults:

- ML/anomaly detection: off.
- `apps.plugin` / `ebpf.plugin` (per-process breakdown): off, not
  needed for a 3-number-per-node view, and it's the heavier
  collectors on constrained boxes.
- Container monitoring: automatic via Netdata's cgroups plugin, no
  extra config, covers per-container CPU/mem the same way `docker
  stats` does.
- Retention: **1 week** (revised down from an initial 1-month ask,
  Telegram alerts cover the "notice something's wrong" need, so deep
  trend history isn't load-bearing). dbengine sized accordingly;
  actual free disk per VPS plan gets checked at implementation time,
  not assumed.
- Target RAM footprint after tuning: roughly 50-80MB vs. Netdata's
  untuned ~150-200MB default, matters most on vps00, which already
  runs the Dokploy control plane (see root `CLAUDE.md` failure log:
  Dokploy alone once ate a disproportionate share of a 2GB node).
- Alert thresholds: tightened from Netdata defaults (e.g. mem/disk
  warn around 80%/90%, not default ~90%/98%), 2GB fills fast, want
  warning before critical.

## Alerting

Netdata's native Telegram notification method. One bot (via
BotFather), token + chat ID configured per node in
`health_alarm_notify.conf`. Fires directly from each VPS, does not
route through the Worker, KV, or the page at all. No mail server, no
new service to run.

## Transport security

New Cloudflare Tunnel **Public Hostname per node** (e.g.
`vps00-metrics.maybeit.work`) → `http://localhost:19999`, reusing
that node's existing `cloudflared` connector/token, this is a new
route, not a new token (rail 2 is about not sharing a token *across*
nodes; one tunnel already carries multiple hostnames fine).

Gated by Cloudflare Access, two policies:
1. **Service token** (machine auth), used by the Worker's Cron
   Trigger to poll. Stored as a Worker secret (`wrangler secret
   put`), never in the repo.
2. **Email/OTP**, allows the account owner to open the raw Netdata
   dashboard in a browser directly, for the odd occasion of wanting
   more than the status page shows.

This is new public-ish surface, reviewed explicitly here rather than
assumed safe by analogy to existing routes.

## Data flow

1. Cron Trigger fires (every 5 min).
2. Worker fetches each node's Netdata API (with Access service-token
   header), wrapped independently per node, so one failure doesn't
   abort the others.
3. Worker fetches `dokploy.maybeit.work` for a plain reachability
   check (control-plane up/down).
4. Assembles one JSON snapshot `{node: {up, cpu, mem, disk,
   lastSeen}, dokploy: {up, lastSeen}}`, writes to Workers KV.
5. On a page view, the `fetch` handler reads that KV snapshot and
   renders it, no origin calls happen on the read path.

## Error handling

- A node's poll times out/errors → that node renders red with "stale
  as of `<lastSeen>`" instead of blanking the page or throwing.
- KV empty (first deploy, before cron has run once) → page shows "no
  data yet," not a crash.
- Cron failures on one node never block writing the others' data,
  independent try/catch per node inside the same cron invocation.

## Testing

Ponytail check: one small test on the render function, status JSON
in, correct red/green + percentage output out. That's the only real
branching logic in the Worker; cron scheduling and fetch plumbing
aren't worth unit-testing for a 3-node homelab page.

## Secrets

- Cloudflare Access service-token credentials → Worker secret.
- Telegram bot token + chat ID → Netdata's local config on each node
  (not the Worker, alerting doesn't go through it).
- Never printed in full in chat/commits per root `CLAUDE.md` rail 11.

## Open items for the implementation plan

- Exact Netdata `netdata.conf` / `health_alarm_notify.conf` diffs per
  node.
- Exact dbengine size for 1-week retention, pinned after checking
  real disk headroom per VPS plan.
- Worker project scaffold (`wrangler.toml`, KV namespace binding,
  Cron Trigger schedule), custom domain binding for the apex.
- New Cloudflare Zero Trust Public Hostnames + Access policies +
  service token, added in the dashboard (same place existing routes
  live, per `stacks/CLAUDE.md`).
