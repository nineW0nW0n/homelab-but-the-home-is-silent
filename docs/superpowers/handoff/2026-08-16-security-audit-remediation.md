# Handoff — security audit remediation plan

**Written:** 2026-08-16, after a full security audit of the repo, the three
deployed nodes, the Cloudflare edge, and the status Worker.

**Audience:** the next agent (Sonnet) executing these fixes. Read
`.claude/CLAUDE.md` (root) and the relevant directory `CLAUDE.md` before
touching anything — the hard rails there apply on top of this document.

**Audit report with the raw findings and evidence:**
`/private/tmp/claude-501/-Users-excollado-homelab-but-the-home-is-silent/283c7136-8729-42c2-8103-303032adf4a8/scratchpad/security-audit-2026-08-16.md`

That report contains **real node IPs**. It lives in the scratchpad deliberately.
**Never commit it, never paste its IPs into any tracked file** (rail 5 — and this
repo is public). This handoff is written without real IPs on purpose; wherever a
node address is needed, read it from `infra/inventory.yaml` (gitignored) at run
time.

---

## Rules for the executor

Non-negotiable, they exist because breaking them is how this list got written:

1. **Never write a real IP into a tracked file.** Not in a comment, not in a
   usage example, not in a commit message. Use `203.0.113.10` style RFC 5737
   documentation addresses, or read from `infra/inventory.yaml`.
2. **Never print a secret in full** — tunnel tokens, SSH keys, Telegram tokens,
   Access client secrets. Redact as `TUNNEL_TOKEN=***redacted***`.
3. **Never touch the SSH allow rule or port 22.** Every firewall change in this
   document explicitly preserves SSH. If you cannot see how a rule preserves it,
   stop and ask.
4. **Confirm with Ex before applying anything that touches the firewall, the
   tunnel, Access policy, or the deploy user.** That is C1, C2, H2, H3. Explain
   in 1–3 plain sentences what will change and what breaks if it goes wrong,
   *before* running it, not after.
5. **One item = one commit**, conventional message, `pre-commit run --all-files`
   green before you report done. Never report done on a red check.
6. **Log every correction** in the failure log of the relevant `CLAUDE.md`, same
   turn as the fix (propagation protocol in root `CLAUDE.md`).
7. **Rollback is `git revert` + push.** Node-side firewall changes have their own
   rollback procedure, given per item below.

### Facts already established — do not re-derive

Confirmed live on 2026-08-16, so you can skip the discovery:

- `dokploy` (Swarm service) publishes `3000` in **`PublishMode: host`**, not
  ingress. Host-mode publish uses the same DNAT path as `docker run -p`, so
  **`DOCKER-USER` filtering applies to it.** No `DOCKER-INGRESS` handling needed
  for this port. Re-verify before relying on it:
  `docker service inspect dokploy --format '{{json .Endpoint.Ports}}'`
- `dokploy-traefik` is a **plain container** (not a Swarm service) publishing
  `80/tcp`, `80/udp`… precisely: `443/tcp`, `443/udp`, `80/tcp`, each bound
  `0.0.0.0` **and `::`**. **IPv6 is bound too — every firewall rule needs an
  `ip6tables` twin or the fix is half a fix.**
- WAN interface on vps00 is **`eth0`**. Verify per node with
  `ip -o -4 route show default`.
- `vps00.maybeit.work` / `vps01.maybeit.work` / `vps02.maybeit.work` have **no
  DNS records** — they are inventory labels only, not resolvable names. Do not
  use them as substitutes for IPs in scripts that actually connect.
- Netdata binds `127.0.0.1:19999` on all three nodes and the three
  `*-metrics.maybeit.work` hostnames correctly `302` to Cloudflare Access
  (`old-firefly-996b.cloudflareaccess.com`). **This part is right — do not
  "fix" it.**
- `dokploy.maybeit.work` returns `200` with **no** Access redirect. That is C1.

---

## Execution order

Items 1–3 are the ones a stranger reading the public repo can exploit today.
Do them in order; do not batch them into one commit.

| # | Item | Severity | Touches |
|---|---|---|---|
| 1 | C1 — Access policy on Dokploy | CRITICAL | Cloudflare only |
| 2 | C2 — Docker bypasses UFW | CRITICAL | node firewall |
| 3 | H1 — real IPs in public repo | HIGH | repo only |
| 4 | H3 — Docker socket in Netdata | HIGH | stacks + deploy |
| 5 | H2 — SSH key blast radius | HIGH | CI + nodes |
| 6 | M1 — secrets in `run:` shell | MEDIUM | workflow |
| 7 | M2 — Worker polls on every request | MEDIUM | worker |
| 8 | M3 — actions pinned by tag | MEDIUM | workflows |
| 9 | M4 — `curl \| sh` bootstrap | MEDIUM | scripts |
| 10 | L1 — public `/debug` | LOW | worker |
| 11 | L2 — no security headers | LOW | worker |

### Decisions Ex has made — do not re-litigate these

- **Item 1 (C1): Plan A.** Cloudflare Access application on
  `dokploy.maybeit.work`, applied through the Zero Trust dashboard via browser
  automation. Includes the service-token fix to `pollDokploy` so the status
  check stays honest.
- **Item 2 (C2): Plan C — both layers.** `DOCKER-USER` drop rules *and*
  `"ip": "127.0.0.1"` in `/etc/docker/daemon.json`. Reasoning Ex gave: self-
  inflicted breakage is recoverable, a stranger's is not, so pay the extra
  layer. Node order stays vps02 → vps01 → vps00.
- **Item 3 (H1): scrub the files *and* rewrite history.** Force-push approved
  for this item specifically. Repo is public with 0 forks and 0 stars, so
  collateral is limited to Ex's own clones.

---

# 1 — C1: Dokploy control plane is publicly reachable

## The problem

`https://dokploy.maybeit.work/` returns `200` and serves the Dokploy login UI.
The three `*-metrics` hostnames sit behind Cloudflare Access; this one does not.
Dokploy can create containers, read every app's environment variables, and open
shells on all three nodes. The only thing in front of it is the admin password.

There is a second, independent path to the same UI — direct IP on `:3000`. That
one is C2's job, because closing it requires the firewall fix. **C1 does not
close the IP path. Do C2 too, or the box is still open.**

## Plan A — Cloudflare Access application on `dokploy.maybeit.work`

Preferred: same mechanism already proven working on the metrics hosts, zero node
changes, no lockout risk to SSH.

1. Zero Trust dashboard → **Access → Applications → Add an application →
   Self-hosted**.
2. Application name `dokploy`, session duration whatever the metrics apps use
   (match them — check an existing app first so the fleet is consistent).
3. Public hostname: `dokploy` . `maybeit.work`, path empty.
4. Policy: **Allow**, include **Emails** → Ex's address. Copy the metrics apps'
   policy rather than inventing a new one — read it first, mirror it.
5. Decide explicitly about a **service token bypass**: the status Worker does
   *not* poll Dokploy through Access (`pollDokploy` in `worker/status/src/poll.js`
   does a plain `GET https://dokploy.maybeit.work/` with no Access headers). Once
   Access is on, that GET will get a `302` to the login page. `res.status < 500`
   is still true for a 302, so **the dashboard will keep showing dokploy as "up"
   and the check becomes meaningless** — it now proves Access is up, not Dokploy.
   Two honest options:
   - add `CF-Access-Client-Id` / `CF-Access-Client-Secret` to `pollDokploy`'s
     request (the Worker already has both bound as secrets, used for Netdata) and
     include the service token in the Dokploy Access policy; or
   - accept the degraded check and write one comment line in `poll.js` saying so.

   Pick the first. It is four lines and keeps the dashboard honest.
6. Verify: `curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n'
   https://dokploy.maybeit.work/` must return `302` to
   `old-firefly-996b.cloudflareaccess.com`. A `200` means the policy did not
   attach.
7. Verify the Worker still reports dokploy correctly: `curl -s
   https://maybeit.work/debug | head -c 400`.

Browser automation via `mcp__claude-in-chrome__*` is available if the dashboard
work is easier driven that way — the previous session used it for GitHub secrets.
Ask Ex first; it touches a live auth policy.

## Plan B — remove the public hostname entirely

Use this if Access cannot be applied (plan limits, policy conflict, or Ex would
rather not have the control plane on the internet at all — a defensible position).

1. Zero Trust → Networks → Tunnels → vps00's tunnel → **Public Hostnames** →
   delete the `dokploy.maybeit.work` → `http://localhost:3000` route.
2. Reach Dokploy from a laptop over SSH instead:
   `ssh -N -L 3000:127.0.0.1:3000 deploy@$(vps00 ip from inventory)` then browse
   `http://localhost:3000`.
3. Update `stacks/CLAUDE.md`'s "Current routes" list and
   `scripts/bootstrap-dokploy.sh`'s closing instructions (step 3 mentions adding
   that route) so the docs match reality.
4. The Worker's `pollDokploy` then has nothing public to poll — either point
   `DOKPLOY_HOST` at something else, or drop the dokploy tile. Coordinate with
   whatever the page expects; `toStatusJson` already excludes dokploy from
   `/status.json`, so only `/debug` and the page's fourth dot are affected.

**Cost of Plan B:** no browser access to Dokploy without an SSH tunnel. That is a
real ergonomic hit for a homelab that gets managed from a phone. Plan A is better
unless Ex says otherwise.

## Also do, regardless of which plan

- Confirm the Dokploy admin account has a strong unique password, and enable 2FA
  if the version supports it.
- Check Dokploy's own audit/login log for sessions Ex does not recognize. The UI
  has been publicly reachable for an unknown period — assume it was found by a
  scanner even if not exploited.
- Note the Dokploy version and check it against upstream advisories.

## Done when

`dokploy.maybeit.work` no longer serves a `200` login page to an unauthenticated
request, and the change is written down in `stacks/CLAUDE.md`.

## Status — DONE

- Access application `dokploy` created (self-hosted, `dokploy.maybeit.work`,
  24h session), policies mirroring the `*-metrics` apps: `status-worker service
  auth` (service token `status-worker`) then `owner email allow` (Emails). Note
  the account's existing policies are **per-app copies, not shared objects** —
  each of the six listed shows "used by 1 application" — so dokploy got its own
  pair rather than binding to another app's policy.
- Verified: unauthenticated `GET https://dokploy.maybeit.work/` returns `302` to
  `old-firefly-996b.cloudflareaccess.com`. The three metrics hosts still `302`,
  `https://maybeit.work/` still `200`.
- `pollDokploy` now sends the service token and uses `redirect: 'manual'` with
  an explicit 2xx test, so the tile cannot go green on an Access login page.
  Verified live after deploy: `/debug` shows `dokploy.up: true` reached through
  the token.
- **Not done, and it is C2's job:** the direct-IP path on `:3000` is still open.
  Access does nothing for it.

## Still open from "Also do, regardless of which plan"

Ex to confirm the Dokploy admin password is strong and unique, enable 2FA if the
version supports it, and check Dokploy's login log for unrecognised sessions —
the UI was publicly reachable for an unknown period.

---

# 2 — C2: Docker's published ports bypass UFW

## The problem

`harden-node.sh` configures UFW deny-incoming and that is genuinely correct — but
Docker inserts its own `nat`/`DOCKER` rules that are evaluated **before** UFW's
`ufw-*` chains. Every published container port is internet-facing regardless of
what UFW says. Observed live:

| node | actually open |
|---|---|
| vps00 | 22, 80, 443, **3000** |
| vps01 | 22, 80, 443 |
| vps02 | 22, 80, 443 |

Rail 1 ("no open inbound ports except SSH") is therefore false in production, and
worse: **any app Dokploy deploys with a published port becomes internet-facing by
default**, skipping the tunnel and Access. Today 80/443 return 404 for unknown
Host headers so nothing is leaking; the next deployed app changes that.

## ⚠️ Lockout warning — read before running anything here

You are editing the firewall of a remote machine whose only management path is
SSH. A wrong rule ends the session permanently and requires the provider's
console to recover.

**Mandatory safety procedure for every node, every time:**

```sh
# 1. snapshot current rules to FIXED paths -- no timestamp, so step 2 can
#    name the file it restores. A placeholder like ".backup.LATEST" is not a
#    filename: the restore silently fails and the safety net is fake.
iptables-save  > /root/iptables.backup
ip6tables-save > /root/ip6tables.backup
test -s /root/iptables.backup  || { echo "empty v4 backup, stop" >&2; exit 1; }
test -s /root/ip6tables.backup || { echo "empty v6 backup, stop" >&2; exit 1; }

# 2. arm a dead-man restore BEFORE applying anything, and keep its PID so
#    step 5 can actually kill it.
setsid sh -c 'sleep 300
  iptables-restore  < /root/iptables.backup
  ip6tables-restore < /root/ip6tables.backup' >/dev/null 2>&1 &
deadman=$!
echo "dead-man armed, pid $deadman, fires in 300s"

# 3. apply the rules

# 4. from a SECOND terminal, prove SSH still works:
#    ssh deploy@<node> 'echo alive'
#    If that fails, do NOTHING -- wait out the 300s and the restore undoes it.

# 5. only then disarm and persist
kill "$deadman"
```

Do vps02 first (no workload on it), then vps01, then vps00 (control plane, most
to lose). Never all three in one go.

## Plan A — `DOCKER-USER` drop rules, IPv4 + IPv6

`DOCKER-USER` is the chain Docker guarantees it will not overwrite, and it is
traversed before Docker's own accept rules. Because `dokploy` publishes `3000` in
**host** mode (verified) and `dokploy-traefik` is a plain container, **all** the
exposed ports on these nodes go through `DOCKER-USER`. No `DOCKER-INGRESS`
special-casing is needed today — but if Dokploy later deploys a Swarm service
with an *ingress*-mode publish, that traffic uses `DOCKER-INGRESS` instead and
this rule will not cover it. Note that in the script's comments.

Add to `scripts/harden-node.sh`, after the UFW block, inside the remote heredoc:

```sh
echo "-- Docker port exposure (DOCKER-USER) --"
wan_if=$(ip -o -4 route show default | awk '{print $5; exit}')
[ -n "$wan_if" ] || { echo "cannot determine WAN interface" >&2; exit 1; }

# Docker's published ports bypass UFW entirely -- its nat/DOCKER rules are
# evaluated before ufw's chains. DOCKER-USER is the one chain Docker will
# not rewrite, and it is traversed before Docker's accepts. Drop all new
# inbound from the WAN to container-published ports; loopback (cloudflared
# runs network_mode: host, so it reaches origins over 127.0.0.1) and
# established flows are untouched. SSH is not a container port and never
# transits this chain -- it stays governed by UFW.
# NOTE: this covers host-mode and plain-container publishes. A Swarm
# service published in *ingress* mode traverses DOCKER-INGRESS instead and
# is NOT covered -- re-check with
#   docker service inspect <svc> --format '{{json .Endpoint.Ports}}'
# whenever a new Swarm workload is added.
for ipt in iptables ip6tables; do
  # idempotent: wipe our previous rules before re-adding
  while $ipt -D DOCKER-USER -i "$wan_if" -m conntrack --ctstate NEW -j DROP \
        2>/dev/null; do :; done
  $ipt -C DOCKER-USER -i "$wan_if" -m conntrack --ctstate NEW -j DROP \
    2>/dev/null || \
  $ipt -I DOCKER-USER 1 -i "$wan_if" -m conntrack --ctstate NEW -j DROP
done

iptables  -S DOCKER-USER
ip6tables -S DOCKER-USER
```

Then persist. `DOCKER-USER` rules do **not** survive a reboot on their own:

```sh
DEBIAN_FRONTEND=noninteractive apt-get -y -qq install iptables-persistent
netfilter-persistent save
```

`iptables-persistent`'s install prompts on a fresh box —
`DEBIAN_FRONTEND=noninteractive` plus preseeding
`iptables-persistent iptables-persistent/autosave_v4 boolean true` (and `_v6`)
via `debconf-set-selections` avoids a hang. Test this on vps02 first; a hung
apt-get on a heredoc'd SSH session is annoying but not dangerous.

**Caveat to verify, not assume:** restoring saved rules at boot can race Docker
creating the `DOCKER-USER` chain. If `netfilter-persistent` fails at boot because
the chain does not exist yet, fall back to a tiny systemd unit ordered
`After=docker.service` that re-applies the two rules.

> **Blocking step, not a nice-to-have.** Reboot vps02 once and confirm with
> `iptables -S DOCKER-USER` / `ip6tables -S DOCKER-USER` that both rules are
> present *after* boot, before touching vps01 or vps00. An unverified
> persistence mechanism is the same as no persistence, and the failure mode is
> silent: the node comes back up wide open and nothing reports it. This is the
> step most likely to get skipped because everything already looks fixed —
> do not report item 2 done without it.

### Verification (run from the laptop, not the node)

```sh
for ip in $(read from infra/inventory.yaml); do
  for p in 22 80 443 3000 2375 2377 19999; do
    nc -z -G 3 -w 3 "$ip" "$p" 2>/dev/null && echo "$ip OPEN $p"
  done
done
```

Expected after the fix: **`22` and nothing else, on all three nodes.**

Then prove nothing broke:
- `curl -s -o /dev/null -w '%{http_code}\n' https://maybeit.work/` → `200`
- `curl -s https://maybeit.work/debug` → all three nodes `"up":true`
- `dokploy.maybeit.work` still reachable (through Access, per C1)
- `booking.maybeit.work` if it is live

The tunnel keeps working because `cloudflared` runs `network_mode: host` and
reaches origins over `127.0.0.1`, which never traverses `DOCKER-USER` with
`-i $wan_if`.

## Plan B — bind Docker's default publish IP to loopback

Use if `DOCKER-USER` turns out to be unreliable on this Docker version, or if the
persistence problem proves nastier than it is worth.

`/etc/docker/daemon.json`:

```json
{
  "ip": "127.0.0.1"
}
```

then `systemctl restart docker`. Any published port that does not specify an
explicit `HostIp` binds to loopback only, which covers `dokploy-traefik`
(`0.0.0.0`) and the host-mode `dokploy` publish.

**Weaknesses, state them to Ex rather than glossing:**
- Restarting the Docker daemon on vps00 restarts the Swarm control plane and
  every container. Schedule it.
- It does **not** apply to Swarm *ingress*-mode publishes, nor to any container
  that explicitly requests `0.0.0.0:PORT:PORT` — Dokploy's UI can generate
  exactly that. So it is a weaker rail than Plan A: it fixes today's exposure but
  a future Dokploy-deployed app can still punch through.
- IPv6 needs `"ip6"` handling separately and support is version-dependent.

If Plan B is chosen, say plainly in `scripts/CLAUDE.md` that rail 1 is enforced
by a *default*, not a *deny*, so the next person knows the guarantee is weaker.

## Plan C — belt and braces (recommended if Ex wants this closed for good)

Do Plan A *and* Plan B. They are independent layers and neither costs anything
ongoing.

## Also update

- `scripts/CLAUDE.md` failure log: one imperative line — "UFW does not govern
  Docker-published ports; they bypass it via the nat/DOCKER chain. Filter in
  `DOCKER-USER` (and `DOCKER-INGRESS` for ingress-mode Swarm publishes), never
  assume `ufw status` reflects real exposure."
- Root `.claude/CLAUDE.md`: rail 1 currently states an intent that nothing
  enforced. Add the enforcement point, same as was done for rail 9 — the failure
  log already records that "a rail without a wired-in check is undetectable
  drift". A `nc` sweep after each provisioning run is the check.

## Done when

The port sweep shows `22` only on all three nodes, the tunnel-served hostnames
still work, and the rules survive a reboot of vps02.

---

# 3 — H1: real node IPs committed to a public repo

## The problem

Rail 5 says real IPs are never committed. Two of the three are, in usage comments:

```
scripts/install-docker.sh:8
scripts/harden-node.sh:11
scripts/cap-dokploy-resources.sh:18
scripts/add-swap.sh:7
scripts/provision-deploy-user.sh:9
```

Published next to a full description of what runs on each node and which ports it
exposes. This is what turns C1 and C2 from theoretical into findable.

## Plan A — replace with RFC 5737 documentation addresses

`203.0.113.0/24` exists exactly for this. Non-routable, unmistakably fake, reads
naturally in a usage line.

1. Edit each of the five comment lines to use `203.0.113.10` (vps00-shaped
   examples) / `203.0.113.11` (vps01-shaped). Keep the surrounding wording.
2. Add one line to each script's header pointing at the real source:
   `# Real addresses live in infra/inventory.yaml (gitignored).`
3. **Do not** substitute `vps00.maybeit.work` — those names have no DNS records
   (verified), so a copy-pasted example would fail confusingly.
4. Grep the whole tree, not just `scripts/`, before declaring it clean:
   ```sh
   grep -rnE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' . \
     --exclude-dir=.git --exclude-dir=node_modules \
     | grep -vE '127\.0\.0\.1|0\.0\.0\.0|203\.0\.113\.|192\.0\.2\.|198\.51\.100\.'
   ```
   Check `docs/`, `README.md`, and every `CLAUDE.md` too.

### Add a guard so it cannot recur

`gitleaks` is already in `.pre-commit-config.yaml` but has no rule for this.

**Plan A guard —** `.gitleaks.toml` with a custom rule:

```toml
[extend]
useDefault = true

[[rules]]
id = "real-node-ip"
description = "Real IPv4 address in a tracked file (rail 5)"
regex = '''\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}\b'''
[rules.allowlist]
regexes = [
  '''127\.0\.0\.1''', '''0\.0\.0\.0''', '''::1''',
  '''203\.0\.113\.\d+''', '''192\.0\.2\.\d+''', '''198\.51\.100\.\d+''',
  '''10\.\d+\.\d+\.\d+''', '''172\.(1[6-9]|2\d|3[01])\.\d+\.\d+''',
  '''192\.168\.\d+\.\d+''',
]
paths = ['''package-lock\.json''', '''node_modules/''']
```

Verify it actually fires — write a real-looking IP into a scratch file, `git add`
it, confirm `pre-commit run gitleaks --all-files` fails, then remove it. **A guard
you did not watch fail is not a guard** (see the rail 9 entry in root's failure
log).

**Plan B guard —** if the gitleaks config format fights back, a `local` pre-commit
hook is five lines and has no schema risk:

```yaml
- repo: local
  hooks:
    - id: no-real-ips
      name: no real IPs (rail 5)
      entry: >
        sh -c 'grep -rnE "\b([0-9]{1,3}\.){3}[0-9]{1,3}\b" "$@"
        | grep -vE "127\.0\.0\.1|0\.0\.0\.0|203\.0\.113\.|192\.0\.2\.|198\.51\.100\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\."
        && { echo "real IP in tracked file -- rail 5"; exit 1; } || exit 0'
      language: system
      types: [text]
      exclude: ^worker/status/(node_modules|package-lock\.json)
```

Do **not** exclude `docs/superpowers/handoff/` from the guard. Handoff documents
are exactly where a real IP gets pasted in from a live investigation; excluding
them creates the blind spot the guard exists to close. This document passes the
guard as written — it uses `203.0.113.x` throughout.

## Plan B for the exposure itself — git history

The IPs are also in git history. Options, in order of laziness:

1. **Accept it and rely on C1/C2.** Recommended. IPs cannot be rotated cheaply,
   the repo is public and likely mirrored/indexed already, and secrecy of an IP
   was never a real control. What matters is that nothing behind those IPs is
   exploitable — which is what items 1 and 2 fix.
2. **Rewrite history** (`git filter-repo`) and force-push. The repo's own root
   `CLAUDE.md` says "expect force-pushes", so this is permitted — but it does not
   un-publish anything already scraped, breaks every existing clone, and costs an
   afternoon. Only worth it if Ex wants a clean history for its own sake.
3. **Rebuild the nodes on new IPs.** Only if Ex was going to rebuild anyway.

Present option 1 as the recommendation with one sentence of reasoning, and let Ex
decide. **Do not force-push history without explicit approval.**

## Done when

The grep above returns nothing, the guard demonstrably fails on a test IP, and
Ex has made a call on history.

## Status — DONE except the GitHub GC request

- Five script usage examples now use `203.0.113.10/.11`, each with a pointer to
  `infra/inventory.yaml`. Tree-wide grep returns nothing.
- Guard is the `no-real-ips` **local** pre-commit hook, not a custom gitleaks
  rule. The gitleaks hook runs `gitleaks protect --staged`, which scans staged
  changes only — in CI nothing is staged, so a custom rule there is a no-op and
  `validate.yml` would never have caught anything. The local hook takes
  filenames, so it fires identically at commit time and under `--all-files`.
  Verified in both directions: a routable address in a tracked file fails,
  `203.0.113.10` passes. (Do not paste the failing test address into a tracked
  file to document it — the guard correctly rejects that too.)
- `pre-commit install` had never been run in this clone, so `git commit` was
  running no checks locally at all. Installed.
- History rewritten with `git filter-repo --replace-text` across all 67 commits
  and force-pushed. Pre-rewrite backup bundle:
  `~/homelab-pre-rewrite-backup.bundle` (outside the repo, keep until the GC
  request is confirmed done).
- **Still open:** GitHub still serves the pre-rewrite commits by SHA — verified
  after the force-push. Ex must open a GitHub Support request asking them to
  garbage-collect unreachable objects on this repo. Until that lands, the old
  addresses remain retrievable by anyone who recorded an old SHA.

---

# 4 — H3: Docker socket mounted into Netdata on all three nodes

## The problem

Every `stacks/*/docker-compose.yml` mounts `/var/run/docker.sock:ro`. The `:ro`
restricts nothing meaningful — it is a socket, and any process that can talk to
it has full Docker API access, which is host root (`docker run -v /:/host`).
Netdata is only reachable via localhost and an Access-gated tunnel, so this needs
a second bug to reach; but it converts any Netdata RCE into instant root on all
three nodes simultaneously.

`/:/host/root:ro,rslave` is a different matter — Netdata's disk collectors
genuinely need it, it is read-only, and it does not grant write anywhere. **Keep
it.**

## Plan A — remove the socket mount

Laziest fix that actually removes the capability.

1. Delete the `- /var/run/docker.sock:/var/run/docker.sock:ro` line from all
   three compose files.
2. **What is lost:** Netdata's cgroup collector uses the socket only to resolve
   container *names*. Container charts keep working; they get labelled by cgroup
   ID instead of a friendly name. Per-container CPU/memory/IO data is read from
   `/sys/fs/cgroup`, which is mounted separately and unaffected.
3. Ask Ex whether anyone actually reads the per-container charts by name. If the
   dashboard is only used for the node-level metrics the status page consumes
   (`system.cpu`, `system.ram`, `disk_space./`, `system.load`, `mem.swap` — see
   `worker/status/src/poll.js`), nothing of value is lost at all.
4. `docker compose config` on each stack, `pre-commit run --all-files`, push,
   let `deploy.yml` roll it out.
5. Verify after deploy: `curl -s https://maybeit.work/debug` — all three nodes
   still `"up":true` with real numbers. That is the actual contract; it does not
   depend on the socket.

## Plan B — front it with a socket proxy

If the container names turn out to matter.

```yaml
  docker-socket-proxy:
    image: tecnativa/docker-socket-proxy:0.3.0   # pin exactly, never :latest
    container_name: docker-socket-proxy
    restart: unless-stopped
    environment:
      CONTAINERS: 1        # everything else stays 0 (deny) by default
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    ports:
      - "127.0.0.1:2375:2375"
    mem_limit: 32m
    mem_reservation: 16m
```

and on the `netdata` service:

```yaml
    environment:
      DOCKER_HOST: tcp://127.0.0.1:2375
```

(dropping the socket volume from `netdata`).

**Be honest about what this buys:** the proxy container still holds the raw
socket, so a compromise *of the proxy* is still host root. What it removes is
Netdata's — a far larger, far more exposed piece of software — access to
anything beyond read-only container listing. That is a real reduction, not a
complete one. Say so in the compose comment.

Note `ports:` on a proxy while item 2 (C2) is in flight: the explicit
`127.0.0.1:` bind means it is never WAN-exposed regardless of the `DOCKER-USER`
outcome. Good. Do not drop the `127.0.0.1:` prefix.

Rail 4 applies: `mem_limit` and `mem_reservation` are mandatory on the new
service. 2GB nodes.

## Done when

Either the mount is gone, or it is behind a `CONTAINERS=1` proxy, and
`https://maybeit.work/debug` still shows three healthy nodes after deploy.

---

# 5 — H2: one SSH key = root on the whole fleet

## The problem

One `SSH_PRIVATE_KEY` GitHub secret authenticates `deploy` on all three nodes.
`provision-deploy-user.sh` adds `deploy` to the `docker` group, and docker group
membership is root-equivalent. So a leak of that one Actions secret is root on
every node, and rail 6's "no sudo" restriction buys nothing.

**Read this before proposing a fix:** removing `deploy` from the `docker` group
and granting `sudo docker compose` instead does **not** help. `deploy` owns
`/opt/stacks/<node>/docker-compose.yml`, so it can write any compose file it
likes and have root run it. Any path that lets CI deploy containers is
root-equivalent by construction. **Do not sell a sudoers rule as a fix — it is
theatre.** The only honest levers are blast radius and secret protection.

## Plan A — per-node SSH keys

Reduces one compromise from three nodes to one.

1. Generate three keypairs locally:
   `ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_vps00 -C 'ci-deploy vps00' -N ''`
   (and `_vps01`, `_vps02`).
2. Install each on its node: `PUBKEY_FILE=~/.ssh/id_ed25519_vps00 \
   scripts/provision-deploy-user.sh vps00 "$(ip from inventory)"`.
   The script already reads `PUBKEY_FILE` — no script change needed. Note it
   **overwrites** `authorized_keys` (`>` not `>>`), so run it once per node with
   the right key and verify login before moving on.
3. Add `SSH_PRIVATE_KEY_VPS00` / `_VPS01` / `_VPS02` as GitHub secrets
   (`gh secret set`).
4. In `deploy.yml`, change each job's ssh-agent step to its own secret.
5. **Keep the old key working until all three are verified.** Sequence: add new
   key alongside old (append, manually), verify CI green, then remove old.
   A one-shot swap that fails leaves CI unable to reach the node.
6. Revoke the old key everywhere and delete `SSH_PRIVATE_KEY` from GitHub.
7. Update `scripts/CLAUDE.md` and `.github/workflows/CLAUDE.md`.

## Plan B — keep one key, protect it harder

Cheaper, less protection. Legitimate for a homelab if Ex prefers it.

1. GitHub → Settings → Environments → `production` → **required reviewers** (Ex).
   The deploy jobs already declare `environment: production`, so this gates every
   run behind a manual approval with no workflow change.
2. Branch protection on `main`: no force-push, require `validate` to pass. Note
   this conflicts with the root `CLAUDE.md`'s "expect force-pushes" line —
   raise it with Ex rather than silently picking one.
3. Rotate the key now on the assumption it may be older than the repo's hygiene.
4. Document plainly, in `.github/workflows/CLAUDE.md`, that `SSH_PRIVATE_KEY` is
   a fleet-root credential. The value of writing it down is that the next person
   treats it accordingly.

Plan A and Plan B compose. If Ex wants one thing only, Plan B step 1 is the
single highest-value action — required reviewers stop an automated exfiltration
path cold.

## Done when

Either the fleet uses per-node keys, or the `production` environment requires
approval — and either way the credential's real privilege level is written down
where the next reader will find it.

---

# 6 — M1: secrets interpolated into `run:` shell in `deploy.yml`

## The problem

Nine steps across the three deploy jobs do this:

```yaml
run: |
  sed -e "s/__TELEGRAM_BOT_TOKEN__/${{ secrets.TELEGRAM_BOT_TOKEN }}/" ...
```

`${{ }}` is substituted into the script text *before* bash parses it. A secret
containing `/` breaks the `sed` expression; one containing a backtick, `$(`, or a
quote executes as shell on the runner. Self-inflicted-only (Ex controls the
secret values), but it is the standard GitHub Actions script-injection footgun and
the fix is two lines per step.

## Plan A — pass through `env:`, reference as `"$VAR"`

The value then reaches the process through the environment and never enters the
script text.

```yaml
      - name: Write remote .env
        env:
          TUNNEL_TOKEN: ${{ secrets.CLOUDFLARE_TUNNEL_TOKEN }}
        run: |
          printf 'CLOUDFLARE_TUNNEL_TOKEN=%s\n' "$TUNNEL_TOKEN" | \
            ssh -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" \
            'umask 077 && cat > /opt/stacks/vps00/.env'

      - name: Write remote health_alarm_notify.conf
        env:
          TELEGRAM_BOT_TOKEN: ${{ secrets.TELEGRAM_BOT_TOKEN }}
          TELEGRAM_CHAT_ID: ${{ secrets.TELEGRAM_CHAT_ID }}
        run: |
          sed \
            -e "s|__TELEGRAM_BOT_TOKEN__|$TELEGRAM_BOT_TOKEN|" \
            -e "s|__TELEGRAM_CHAT_ID__|$TELEGRAM_CHAT_ID|" \
            stacks/vps00/health_alarm_notify.conf.template | \
            ssh -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" \
            'umask 077 && cat > /opt/stacks/vps00/health_alarm_notify.conf'
```

Note the `|` delimiter instead of `/` — Telegram bot tokens contain `:` and `-`
but a `/` in any future secret would still break a `/`-delimited `sed`.
Repeat for all three jobs (six steps total).

## Plan B — `envsubst`, no delimiter problem at all

If any secret could contain `|` as well:

```yaml
        env:
          TELEGRAM_BOT_TOKEN: ${{ secrets.TELEGRAM_BOT_TOKEN }}
          TELEGRAM_CHAT_ID: ${{ secrets.TELEGRAM_CHAT_ID }}
        run: |
          envsubst '$TELEGRAM_BOT_TOKEN $TELEGRAM_CHAT_ID' \
            < stacks/vps00/health_alarm_notify.conf.template | \
            ssh ... 'umask 077 && cat > /opt/stacks/vps00/health_alarm_notify.conf'
```

This requires renaming the template's placeholders from `__TELEGRAM_BOT_TOKEN__`
to `$TELEGRAM_BOT_TOKEN` in all three `.template` files. Slightly larger diff,
completely delimiter-proof. Either is fine; Plan A is the smaller change.

## Verification

`actionlint` via pre-commit must pass. Then push and confirm the deploy run is
green and Telegram alerts still fire — the previous session verified alerting with
Netdata's test command; reuse that method rather than inventing one. Check
`/opt/stacks/vps00/health_alarm_notify.conf` on the node contains a real token
(do not print it — `grep -c 'TELEGRAM_BOT_TOKEN=""' ` or check length only).

## Done when

No `${{ secrets.* }}` appears inside any `run:` script body in the repo:
`grep -n 'secrets\.' .github/workflows/*.yml` should show them only under `env:`
or `with:` keys.

---

# 7 — M2: the Worker polls the whole fleet on every request

## The problem

`worker/status/src/index.js` calls `pollAll` **and** `STATUS_KV.put` on every
single fetch — including `/`, `/favicon.ico`, and any 404 path. Each poll is five
Netdata API calls per node (fifteen total) against 2 vCPU boxes, plus a KV write.
Anyone with `curl` in a loop turns the public status page into a load generator
against the homelab and a Workers-KV bill.

The comment above the handler explains *why* it polls per-request (Cron Triggers
get a 403 from Access; documented in `worker/status/CLAUDE.md`). **That reasoning
is sound — do not undo it.** The fix is caching, not going back to cron.

## Plan A — staleness check on the cached snapshot

```js
const POLL_TTL_MS = 30_000

export default {
  async fetch(request, env, ctx) {
    const pathname = new URL(request.url).pathname
    // The HTML page fetches /status.json itself -- serving the shell needs
    // no poll at all.
    const needsData = pathname === '/status.json' || pathname === '/debug'
    if (!needsData) {
      return new Response(page, {
        headers: { 'content-type': 'text/html; charset=utf-8' },
      })
    }

    const previous = await env.STATUS_KV.get(SNAPSHOT_KEY, { type: 'json' })
    const polledAt = Date.parse(previous?.polledAt ?? 0)
    const fresh = previous && Date.now() - polledAt < POLL_TTL_MS

    let snapshot = previous
    if (!fresh) {
      snapshot = await pollAll(env, fetch, previous)
      snapshot.polledAt = new Date().toISOString()
      ctx.waitUntil(env.STATUS_KV.put(SNAPSHOT_KEY, JSON.stringify(snapshot)))
    }
    ...
  },
}
```

Points to get right:
- Add a top-level `polledAt` in `pollAll`'s return rather than digging into
  `nodes.vps00.lastPolled` — a per-node field is the wrong thing to key cache
  freshness on, and `vps00` may not exist in the snapshot.
- `ctx.waitUntil` for the KV write so the response is not blocked on it. This
  means adding `ctx` to the handler signature.
- Keep the `previous` snapshot threading — `pollNode` needs it for `lastSeen`
  carry-forward on a down node. Do not break that.

**Tests are mandatory here.** `worker/status/test/poll.test.js` exists and
`npm test` runs in `deploy-worker.yml`. Add cases: a fresh snapshot does **not**
call `pollAll`'s fetch; a stale one does; a missing snapshot does. `pollAll`
already takes an injectable `fetchFn` — count calls on a stub.

## Plan B — Cache API on `/status.json`, static shell on `/`

If the KV-staleness approach gets fiddly:

```js
if (pathname === '/status.json') {
  const cache = caches.default
  const hit = await cache.match(request)
  if (hit) return hit
  const res = Response.json(toStatusJson(snapshot, nodeHosts), {
    headers: { 'cache-control': 'public, max-age=30' },
  })
  ctx.waitUntil(cache.put(request, res.clone()))
  return res
}
```

Cheaper to write, but the cache is per-colo — with traffic from many regions you
get one poll per colo per 30s rather than one globally. For this traffic volume
that is fine, and it is a smaller diff. **Either plan is acceptable; do not do
both.**

Optionally add a Cloudflare rate-limiting rule on `maybeit.work` as a backstop.
That is dashboard config, not code, and needs Ex.

## Done when

`for i in $(seq 20); do curl -s -o /dev/null https://maybeit.work/; done` produces
at most one poll cycle (check `polledAt` on `/debug` does not advance 20 times),
the page still renders live numbers, and `npm test` is green.

---

# 8 — M3: actions pinned by mutable tag

## The problem

`actions/checkout@v4`, `webfactory/ssh-agent@v0.9.0`,
`cloudflare/wrangler-action@v3`, `actions/setup-node@v4`, `actions/cache@v4`.
Tags are mutable — a compromised upstream tag runs with `SSH_PRIVATE_KEY` and
`CLOUDFLARE_API_TOKEN` in scope. The repo already pins every pre-commit hook rev
exactly, and root's failure log says to pin exact versions and never `latest`;
this is the same rule, unapplied.

## Plan A — pin to full commit SHAs

```sh
gh api repos/actions/checkout/git/ref/tags/v4 --jq .object.sha
```

(for a tag pointing at a tag object, resolve through
`gh api repos/OWNER/REPO/commits/TAG --jq .sha` instead).

```yaml
      - uses: actions/checkout@<40-char-sha>  # v4.2.2
```

The trailing comment is what makes this maintainable — without it nobody can tell
what version is pinned. Do all five, in both `deploy.yml` and
`deploy-worker.yml` and `validate.yml`.

Then enable Dependabot so the SHAs still get bumped —
`.github/dependabot.yml`:

```yaml
---
version: 2
updates:
  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: weekly
  - package-ecosystem: npm
    directory: /worker/status
    schedule:
      interval: weekly
```

The npm entry also covers `wrangler`, which is currently the only runtime
dependency and is already pinned exactly in `package.json`. Good.

## Plan B — Dependabot only, keep tags

If SHA pinning is judged too noisy for a homelab. Weaker: Dependabot tells you
about *published* new versions, it does nothing about a retagged malicious `v4`.
State that limitation rather than presenting it as equivalent.

## Done when

`grep -nE 'uses: .*@v[0-9]' .github/workflows/*.yml` returns nothing (Plan A), or
`.github/dependabot.yml` exists and the trade-off is documented (Plan B).

---

# 9 — M4: `curl | sh` root bootstrap

## The problem

`scripts/install-docker.sh` pipes `https://get.docker.com` into a root shell;
`scripts/bootstrap-dokploy.sh` pipes `https://dokploy.com/install.sh`. Both are
unverified remote code executed as root, on an unpinned URL. One-time bootstrap,
vendor-documented path, small window — but it is a decision that should be
recorded rather than inherited by accident.

Note `bootstrap-dokploy.sh` runs as `deploy` (default `VPS00_SSH_USER=deploy`),
who is in the `docker` group, i.e. effectively root anyway (see item 5).

## Plan A — Docker from Debian's official apt repository

This is also what the global convention asks for ("prefer platform defaults,
native tools over abstractions"). Replace the `curl | sh` in
`install-docker.sh`'s heredoc:

```sh
command -v docker >/dev/null 2>&1 || {
  apt-get -qq update >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get -y -qq install \
    ca-certificates curl gnupg >/dev/null
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg \
    -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian %s stable\n' \
    "$(dpkg --print-architecture)" "$(. /etc/os-release && echo "$VERSION_CODENAME")" \
    > /etc/apt/sources.list.d/docker.list
  apt-get -qq update >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get -y -qq install \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin \
    docker-compose-plugin >/dev/null
}
```

Every subsequent package comes GPG-verified through apt, and upgrades arrive
through the normal channel. The initial key fetch is still trust-on-first-use over
TLS — that residual is unavoidable short of shipping the key in the repo, which
is a reasonable Plan A+ if Ex wants it.

The script must stay idempotent (`command -v docker` guard already handles it) and
shellcheck-clean under `-s sh`.

Dokploy has no apt repository. For `bootstrap-dokploy.sh`, download to a file,
print the sha256 so it lands in the CI/terminal log, then execute:

```sh
ssh ... 'set -eu
  tmp=$(mktemp)
  curl -fsSL https://dokploy.com/install.sh -o "$tmp"
  echo "installer sha256: $(sha256sum "$tmp" | cut -d" " -f1)"
  sh "$tmp"
  rm -f "$tmp"'
```

This does not *verify* anything on first run — it makes the artifact
reviewable and gives a hash to compare on the next run. Say that plainly in the
comment rather than implying it is a checksum check.

## Plan B — document the decision, change nothing

Entirely defensible for a homelab. Add three comment lines to each script
recording that this is an accepted, deliberate trust-on-first-use of the vendor's
installer, and one line in `scripts/CLAUDE.md`. The value is that it stops being
an accident.

If Ex picks Plan B, do not quietly do Plan A anyway.

## Done when

Both scripts either use the verified path or carry the recorded decision, and
`shellcheck -s sh scripts/*.sh` is clean plus the idempotency re-run check from
root `CLAUDE.md`'s loop is done and stated.

---

# 10 — L1: `/debug` is public

`https://maybeit.work/debug` returns the raw snapshot, including per-node `error`
strings (Netdata internals, HTTP status codes) and Dokploy reachability. Minor
recon aid, no secrets.

**Plan A — delete the route.** It was a diagnostic escape hatch; `wrangler tail`
covers live debugging and the same data is one `wrangler kv key get` away. Lazy,
removes the surface entirely, costs a little convenience.

**Plan B — gate it.** Require a header matched against a Worker secret:

```js
if (pathname === '/debug') {
  if (request.headers.get('x-debug-key') !== env.DEBUG_KEY) {
    return new Response('not found', { status: 404 })
  }
  return Response.json(snapshot)
}
```

Add `DEBUG_KEY` to the `secrets:` list in `deploy-worker.yml` and as a GitHub
secret. Return `404`, not `403` — do not confirm the route exists.

Keep whichever choice consistent with item 7: if `/debug` survives, it is one of
the two `needsData` paths.

**Done when** an unauthenticated `GET /debug` returns `404`.

---

# 11 — L2: no security headers on the status page

The Worker's HTML response sets only `content-type`. The page has no user input
and does not inject data as HTML — verified: the only `innerHTML` reference is a
static `html:not(.js)` CSS selector at `page.html:68`, and data goes through
`textContent` at `page.html:661`. So this is defense in depth, not a live XSS.

**Plan A — add headers to the HTML response:**

```js
return new Response(page, {
  headers: {
    'content-type': 'text/html; charset=utf-8',
    'content-security-policy':
      "default-src 'self'; style-src 'self' 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'",
    'x-content-type-options': 'nosniff',
    'referrer-policy': 'no-referrer',
  },
})
```

**Check the page's actual inline content before committing to that CSP** — read
`page.html` and confirm whether the script is inline (needs `'unsafe-inline'` for
`script-src`, or a nonce/hash) and whether any font or image is remote. A CSP that
breaks the page is worse than none. Test with `wrangler dev` and watch the browser
console for violations before pushing.

HSTS is unnecessary — Cloudflare terminates TLS and can set it at the edge; if Ex
wants it, do it in the dashboard, not in the Worker.

**Plan B — set them as Cloudflare Transform Rules** (Rules → Response Header
Transform) instead of in code. Same effect, no deploy needed to tweak, but the
config then lives outside the repo, which cuts against GitOps. Prefer Plan A.

**Done when** `curl -sI https://maybeit.work/` shows the headers and the page
renders with a clean console.

---

## Closing checklist for the whole job

Run before reporting the overall work done:

```sh
pre-commit run --all-files
shellcheck -s sh scripts/*.sh
find . -name CLAUDE.md -not -path './node_modules/*' \
  -not -path './worker/status/node_modules/*' -exec wc -l {} +
cd worker/status && npm test
```

Plus the live re-verification, which is the only thing that actually proves items
1 and 2:

```sh
# port sweep -- expect 22 only, all three nodes
# (read IPs from infra/inventory.yaml, never hardcode them)
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' https://dokploy.maybeit.work/
curl -s -o /dev/null -w '%{http_code}\n' https://maybeit.work/
curl -s https://maybeit.work/debug   # or its gated replacement
```

Budget check: root `.claude/CLAUDE.md` is capped at ~500 lines and each directory
file at ~250. Items 2, 4, 5, 6 and 9 all add failure-log lines — if a file goes
over, that is a signal to move content into a skill, not to trim the log. Ask
before restructuring.

Finally: recommend a self-audit to Ex when this is done. Root's rule is to
recommend one when the failure log gains 3+ entries in a session or a hard rail
needed double-checking against real behaviour. This work does both — rail 1 was
false in production and rail 5 was broken in five files.
