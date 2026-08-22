# SIEM-ish log centralisation on vps02 (OpenObserve) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every node ships its systemd journal (sshd, sudo, Fail2Ban, AIDE, all container stdout) to one OpenObserve instance on vps02, browsable at `siem.maybeit.work` behind Cloudflare Access.

**Architecture:** OpenObserve (single binary, local Parquet) and a Vector shipper run on vps02 from `stacks/vps02/`; vps00 and vps01 run only Vector, posting over HTTPS to `siem-ingest.maybeit.work` on vps02's existing tunnel. Docker's log driver switches to `journald` so Vector needs one source and no socket. AIDE is installed natively and logs through `logger`.

**Tech Stack:** `openobserve/openobserve:v0.92.2`, `timberio/vector:0.57.0-debian`, Docker Compose (classic `mem_limit`), GitHub Actions `deploy.yml`, POSIX `sh` provisioning scripts, Cloudflare Tunnel + Access.

**Spec:** `docs/superpowers/specs/2026-08-22-siem-openobserve-design.md`

## Global Constraints

- Rail 1: no new inbound port. OpenObserve binds `127.0.0.1:5080` only; sweep list becomes 22/80/443/2377/3000/5080/19999.
- Rail 2: `siem` and `siem-ingest` hostnames go on vps02's tunnel (`CLOUDFLARE_TUNNEL_TOKEN_VPS02_METRICS`); no token is shared.
- Rail 3: `cloudflared` stays `network_mode: host` (untouched).
- Rail 4: every new service has `mem_limit` and `mem_reservation`; no `deploy:` block. `check-rails.sh` enforces.
- Rail 5: no real IPs anywhere; scripts take `<host>` like the others.
- Rail 11: never print `OPENOBSERVE_*`, `CF_ACCESS_SIEM_*` values. `.env` is written by `deploy.yml` only.
- No `docker.sock` mount on any service (`stacks/CLAUDE.md`).
- Images pinned to exact tags. Both tags verified present on Docker Hub 2026-08-22.
- Memory caps (hedged, measure after a week): openobserve 384m/192m, vector 128m/64m.
- Retention `ZO_COMPACT_DATA_RETENTION_DAYS=30`; journald `SystemMaxUse=1G`.
- Definition of done per root `CLAUDE.md`: `docker compose config` per stack, `pre-commit run --all-files`, `shellcheck scripts/*.sh`, budget line `git ls-files '*CLAUDE.md' | xargs wc -l`, scripts idempotent (second run no-op).
- Branch: `feat/siem-openobserve` (exists, off `main`). Commit messages conventional, end with the `Co-Authored-By` / `Claude-Session` trailers used in this session.
- Commands run under the rtk hook; that is fine for everything here.

---

## File map

| Path | Change | Responsibility |
|---|---|---|
| `stacks/vps02/docker-compose.yml` | modify | add `openobserve` + `vector` services, `openobserve-data` + `vector-data` volumes |
| `stacks/vps02/vector.yaml` | create | shipper config; identical on all three nodes |
| `stacks/vps00/docker-compose.yml` | modify | add `vector` service + `vector-data` volume |
| `stacks/vps00/vector.yaml` | create | byte-identical copy of vps02's |
| `stacks/vps01/docker-compose.yml` | modify | same as vps00 |
| `stacks/vps01/vector.yaml` | create | byte-identical copy |
| `scripts/check-rails.sh` | modify | assert the three `vector.yaml` are identical; sweep list gains 5080 |
| `.github/workflows/deploy.yml` | modify | `.env` gains SIEM values per node; verify steps probe openobserve + vector |
| `scripts/setup-maintenance.sh` | modify | `log-driver: journald`, `SystemMaxUse=1G` |
| `scripts/install-aide.sh` | create | AIDE install, init, daily update-and-log cron |
| `stacks/CLAUDE.md`, `scripts/CLAUDE.md`, `.claude/CLAUDE.md`, `README.md` | modify | docs and rails |
| `docs/superpowers/specs/2026-08-22-siem-openobserve-design.md` | modify | secrets table: ingest auth is user+password, not one base64 value |

---

### Task 1: vps02 stack — OpenObserve and Vector

**Files:**
- Modify: `stacks/vps02/docker-compose.yml` (append services and volumes)
- Create: `stacks/vps02/vector.yaml`

**Interfaces:**
- Produces: `vector.yaml` consumed unchanged by Tasks 2 and 3; env var names `OPENOBSERVE_INGEST_URL`, `OPENOBSERVE_INGEST_USER`, `OPENOBSERVE_INGEST_PASSWORD`, `CF_ACCESS_SIEM_CLIENT_ID`, `CF_ACCESS_SIEM_CLIENT_SECRET`, `NODE_NAME` consumed by Tasks 2 and 4.

- [ ] **Step 1: Write `stacks/vps02/vector.yaml`**

```yaml
# Vector shipper. One source (the host systemd journal), one sink
# (OpenObserve). This file is byte-identical on vps00, vps01 and vps02
# on purpose -- check-rails.sh fails if the three copies drift. Per-node
# differences are environment only (compose sets NODE_NAME and
# OPENOBSERVE_INGEST_URL; deploy.yml writes the credentials to .env).
#
# No docker.sock: container stdout reaches the journal through Docker's
# journald log driver (scripts/setup-maintenance.sh), so the journal is
# the only thing Vector reads.
data_dir: /var/lib/vector

sources:
  journal:
    type: journald
    journal_directory: /var/log/journal
    # Ship history on first start, not just this boot; the checkpoint in
    # data_dir stops re-sends after that.
    current_boot_only: false

transforms:
  tag_node:
    type: remap
    inputs: [journal]
    source: |
      .node = "${NODE_NAME:?NODE_NAME must be set}"

sinks:
  openobserve:
    type: http
    inputs: [tag_node]
    uri: "${OPENOBSERVE_INGEST_URL:?OPENOBSERVE_INGEST_URL must be set}/api/default/journal/_json"
    method: post
    auth:
      strategy: basic
      user: "${OPENOBSERVE_INGEST_USER:?OPENOBSERVE_INGEST_USER must be set}"
      password: "${OPENOBSERVE_INGEST_PASSWORD:?OPENOBSERVE_INGEST_PASSWORD must be set}"
    compression: gzip
    encoding:
      codec: json
      timestamp_format: rfc3339
    batch:
      max_events: 500
      timeout_secs: 5
    request:
      # Cloudflare Access service token. Empty on vps02, which posts to
      # localhost and never crosses the edge; OpenObserve ignores them.
      headers:
        CF-Access-Client-Id: "${CF_ACCESS_SIEM_CLIENT_ID:-}"
        CF-Access-Client-Secret: "${CF_ACCESS_SIEM_CLIENT_SECRET:-}"
    # Off: the healthcheck would hit the bare URI, which Access answers
    # with a redirect, and Vector would refuse to start on vps00/vps01.
    healthcheck:
      enabled: false
```

- [ ] **Step 2: Append to `stacks/vps02/docker-compose.yml`**

Insert these two services after the `netdata` service (before the top-level `volumes:`), and add the two volumes to the existing `volumes:` block.

```yaml
  openobserve:
    # Log store + UI. Single binary, local Parquet under /data. Reached
    # only via vps02's tunnel: siem.maybeit.work (UI, Access email
    # policy) and siem-ingest.maybeit.work (Vector on vps00/vps01,
    # Access service token). Spec:
    # docs/superpowers/specs/2026-08-22-siem-openobserve-design.md
    image: openobserve/openobserve:v0.92.2
    container_name: openobserve
    restart: unless-stopped
    ports:
      # Loopback explicitly (rail 1), on top of daemon.json's default
      # bind. Belt and braces: a daemon.json regression must not open it.
      - "127.0.0.1:5080:5080"
    environment:
      ZO_ROOT_USER_EMAIL: ${OPENOBSERVE_ROOT_EMAIL}
      ZO_ROOT_USER_PASSWORD: ${OPENOBSERVE_ROOT_PASSWORD}
      ZO_DATA_DIR: /data
      ZO_COMPACT_DATA_RETENTION_DAYS: "30"
      ZO_TELEMETRY: "false"
      # MB. Default sizes the cache from host RAM, not the cgroup limit;
      # hedged, raise if queries feel slow and the container stays well
      # under mem_limit.
      ZO_MEMORY_CACHE_MAX_SIZE: "64"
    volumes:
      - openobserve-data:/data
    # Rail 4. Hedged until measured; revisit after a week of real logs.
    mem_limit: 384m
    mem_reservation: 192m

  vector:
    # Ships this node's journal to OpenObserve. See vector.yaml.
    image: timberio/vector:0.57.0-debian
    container_name: vector
    restart: unless-stopped
    # Host netns so 127.0.0.1:5080 is the OpenObserve port above.
    network_mode: host
    environment:
      NODE_NAME: vps02
      OPENOBSERVE_INGEST_URL: http://127.0.0.1:5080
      OPENOBSERVE_INGEST_USER: ${OPENOBSERVE_INGEST_USER}
      OPENOBSERVE_INGEST_PASSWORD: ${OPENOBSERVE_INGEST_PASSWORD}
    volumes:
      - ./vector.yaml:/etc/vector/vector.yaml:ro
      - vector-data:/var/lib/vector
      - /var/log/journal:/var/log/journal:ro
      - /run/log/journal:/run/log/journal:ro
      - /etc/machine-id:/etc/machine-id:ro
    mem_limit: 128m
    mem_reservation: 64m
```

```yaml
volumes:
  netdataconfig:
  netdatalib:
  netdatacache:
  openobserve-data:
  vector-data:
```

- [ ] **Step 3: Validate the compose file**

Run (placeholders are fake, local only, never committed):
```sh
cd stacks/vps02 && \
CLOUDFLARE_TUNNEL_TOKEN_VPS02_METRICS=x OPENOBSERVE_ROOT_EMAIL=x OPENOBSERVE_ROOT_PASSWORD=x \
OPENOBSERVE_INGEST_USER=x OPENOBSERVE_INGEST_PASSWORD=x \
docker compose config --quiet && echo OK; cd ../..
```
Expected: `OK`. Then `scripts/check-rails.sh` — expected last line `check-rails: rails 1 (partial), 2, 3, 4, 7 + markup sinks OK across 3 compose files`.

- [ ] **Step 4: Validate vector.yaml syntax locally**

```sh
docker run --rm -v "$PWD/stacks/vps02/vector.yaml:/etc/vector/vector.yaml:ro" \
  -e NODE_NAME=x -e OPENOBSERVE_INGEST_URL=http://127.0.0.1:5080 \
  -e OPENOBSERVE_INGEST_USER=x -e OPENOBSERVE_INGEST_PASSWORD=x \
  timberio/vector:0.57.0-debian validate --no-environment /etc/vector/vector.yaml
```
Expected: `Validated`. If `request.headers` or `healthcheck.enabled` are rejected, the 0.57 key names moved: check `vector validate` output and fix the key, do not drop the setting.

- [ ] **Step 5: Commit**

```sh
git add stacks/vps02/docker-compose.yml stacks/vps02/vector.yaml
git commit -m "feat(vps02): run OpenObserve and a Vector journal shipper"
```

---

### Task 2: vps00 and vps01 — Vector only

**Files:**
- Modify: `stacks/vps00/docker-compose.yml`, `stacks/vps01/docker-compose.yml`
- Create: `stacks/vps00/vector.yaml`, `stacks/vps01/vector.yaml` (copies)

**Interfaces:**
- Consumes: `stacks/vps02/vector.yaml` from Task 1, byte-identical.

- [ ] **Step 1: Copy the shipper config**

```sh
cp stacks/vps02/vector.yaml stacks/vps00/vector.yaml
cp stacks/vps02/vector.yaml stacks/vps01/vector.yaml
```

- [ ] **Step 2: Add the `vector` service to both compose files**

Append after each file's `netdata` service. Only `NODE_NAME` differs (`vps00` / `vps01`).

```yaml
  vector:
    # Ships this node's journal to OpenObserve on vps02 over vps02's
    # tunnel. Outbound HTTPS only (rail 1). Two locks on the way in:
    # the CF-Access service token headers and OpenObserve basic auth.
    # See stacks/vps02/vector.yaml for the config, kept identical here.
    image: timberio/vector:0.57.0-debian
    container_name: vector
    restart: unless-stopped
    network_mode: host
    environment:
      NODE_NAME: vps00
      OPENOBSERVE_INGEST_URL: https://siem-ingest.maybeit.work
      OPENOBSERVE_INGEST_USER: ${OPENOBSERVE_INGEST_USER}
      OPENOBSERVE_INGEST_PASSWORD: ${OPENOBSERVE_INGEST_PASSWORD}
      CF_ACCESS_SIEM_CLIENT_ID: ${CF_ACCESS_SIEM_CLIENT_ID}
      CF_ACCESS_SIEM_CLIENT_SECRET: ${CF_ACCESS_SIEM_CLIENT_SECRET}
    volumes:
      - ./vector.yaml:/etc/vector/vector.yaml:ro
      - vector-data:/var/lib/vector
      - /var/log/journal:/var/log/journal:ro
      - /run/log/journal:/run/log/journal:ro
      - /etc/machine-id:/etc/machine-id:ro
    mem_limit: 128m
    mem_reservation: 64m
```

Add `vector-data:` to each file's top-level `volumes:` block.

- [ ] **Step 3: Validate both**

```sh
for n in vps00 vps01; do (cd stacks/$n && \
  CLOUDFLARE_TUNNEL_TOKEN=x CLOUDFLARE_TUNNEL_TOKEN_VPS01_BOOKING=x \
  OPENOBSERVE_INGEST_USER=x OPENOBSERVE_INGEST_PASSWORD=x \
  CF_ACCESS_SIEM_CLIENT_ID=x CF_ACCESS_SIEM_CLIENT_SECRET=x \
  docker compose config --quiet && echo "$n OK"); done
```
Expected: `vps00 OK`, `vps01 OK`. vps01's compose may need other env names it already uses; read its `Write remote .env` step in `deploy.yml` for the full list and pass them as `x`.

- [ ] **Step 4: Commit**

```sh
git add stacks/vps00 stacks/vps01
git commit -m "feat(vps00,vps01): ship the journal to OpenObserve with Vector"
```

---

### Task 3: check-rails — identical shipper configs, sweep list

**Files:**
- Modify: `scripts/check-rails.sh` (before the final `[ "$fail" -eq 0 ]` line; and the two `echo` lines that print the sweep list)

- [ ] **Step 1: Add the identity check**

Insert before `[ "$fail" -eq 0 ] || ...`:

```sh
# --- vector.yaml: three copies, one file ------------------------------
# The shipper config is deployed per node (deploy.yml rsyncs one
# directory each) so it exists three times. Two copies do not stay equal
# (root CLAUDE.md failure log, the 2026-08-20 directory split), so this
# asserts they are byte-identical. Per-node differences belong in the
# compose environment, never in this file.
v0=stacks/vps00/vector.yaml
v1=stacks/vps01/vector.yaml
v2=stacks/vps02/vector.yaml
if [ -f "$v0" ] && [ -f "$v1" ] && [ -f "$v2" ]; then
  cmp -s "$v0" "$v2" || err "$v0 differs from $v2 -- vector.yaml must be identical on all nodes"
  cmp -s "$v1" "$v2" || err "$v1 differs from $v2 -- vector.yaml must be identical on all nodes"
else
  err "vector.yaml missing on a node -- expected $v0 $v1 $v2"
fi
```

Change the sweep echo to:
```sh
echo "        are closed: nc -z -w 3 <ip> 22 80 443 2377 3000 5080 19999"
```

- [ ] **Step 2: Watch it fail, then pass**

```sh
printf '\n# drift\n' >> stacks/vps01/vector.yaml && scripts/check-rails.sh; echo "exit=$?"
git checkout stacks/vps01/vector.yaml && scripts/check-rails.sh; echo "exit=$?"
```
Expected: first run prints `FAIL ... differs ...` and `exit=1`; second prints the OK line and `exit=0`. A check nobody saw fail is not a check.

- [ ] **Step 3: Commit**

```sh
shellcheck -s sh scripts/check-rails.sh
git add scripts/check-rails.sh
git commit -m "feat(check-rails): assert vector.yaml is identical on all nodes; sweep list gains 5080"
```

---

### Task 4: deploy.yml — secrets into .env, verify the new containers

**Files:**
- Modify: `.github/workflows/deploy.yml` — the three `Write remote .env` steps and the three `Verify` steps.

**Interfaces:**
- Consumes: env names from Task 1. GitHub secrets (Ex creates, Task 8): `OPENOBSERVE_ROOT_EMAIL`, `OPENOBSERVE_ROOT_PASSWORD`, `OPENOBSERVE_INGEST_USER`, `OPENOBSERVE_INGEST_PASSWORD`, `CF_ACCESS_SIEM_CLIENT_ID`, `CF_ACCESS_SIEM_CLIENT_SECRET`.

- [ ] **Step 1: vps00 `.env`**

Replace the `env:` block and `printf` of the vps00 `Write remote .env` step with:

```yaml
        env:
          TUNNEL_TOKEN: ${{ secrets.CLOUDFLARE_TUNNEL_TOKEN }}
          NETDATA_CLAIM_TOKEN: ${{ secrets.NETDATA_CLAIM_TOKEN }}
          NETDATA_CLAIM_ROOMS: ${{ secrets.NETDATA_CLAIM_ROOMS }}
          OPENOBSERVE_INGEST_USER: ${{ secrets.OPENOBSERVE_INGEST_USER }}
          OPENOBSERVE_INGEST_PASSWORD: ${{ secrets.OPENOBSERVE_INGEST_PASSWORD }}
          CF_ACCESS_SIEM_CLIENT_ID: ${{ secrets.CF_ACCESS_SIEM_CLIENT_ID }}
          CF_ACCESS_SIEM_CLIENT_SECRET: ${{ secrets.CF_ACCESS_SIEM_CLIENT_SECRET }}
        run: |
          # One file, one write: this is 'cat >', not '>>', so every value
          # the stack needs has to be printed here or it is lost.
          printf 'CLOUDFLARE_TUNNEL_TOKEN=%s\nNETDATA_CLAIM_TOKEN=%s\nNETDATA_CLAIM_ROOMS=%s\nOPENOBSERVE_INGEST_USER=%s\nOPENOBSERVE_INGEST_PASSWORD=%s\nCF_ACCESS_SIEM_CLIENT_ID=%s\nCF_ACCESS_SIEM_CLIENT_SECRET=%s\n' \
            "$TUNNEL_TOKEN" "$NETDATA_CLAIM_TOKEN" "$NETDATA_CLAIM_ROOMS" \
            "$OPENOBSERVE_INGEST_USER" "$OPENOBSERVE_INGEST_PASSWORD" \
            "$CF_ACCESS_SIEM_CLIENT_ID" "$CF_ACCESS_SIEM_CLIENT_SECRET" | \
            ssh -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" \
            'umask 077 && cat > /opt/stacks/vps00/.env'
```

- [ ] **Step 2: vps01 `.env`**

```yaml
        env:
          TUNNEL_TOKEN: ${{ secrets.CLOUDFLARE_TUNNEL_TOKEN_VPS01_BOOKING }}
          NETDATA_CLAIM_TOKEN: ${{ secrets.NETDATA_CLAIM_TOKEN }}
          NETDATA_CLAIM_ROOMS: ${{ secrets.NETDATA_CLAIM_ROOMS }}
          OPENOBSERVE_INGEST_USER: ${{ secrets.OPENOBSERVE_INGEST_USER }}
          OPENOBSERVE_INGEST_PASSWORD: ${{ secrets.OPENOBSERVE_INGEST_PASSWORD }}
          CF_ACCESS_SIEM_CLIENT_ID: ${{ secrets.CF_ACCESS_SIEM_CLIENT_ID }}
          CF_ACCESS_SIEM_CLIENT_SECRET: ${{ secrets.CF_ACCESS_SIEM_CLIENT_SECRET }}
        run: |
          # One file, one write: this is 'cat >', not '>>', so every value
          # the stack needs has to be printed here or it is lost.
          printf 'CLOUDFLARE_TUNNEL_TOKEN_VPS01_BOOKING=%s\nNETDATA_CLAIM_TOKEN=%s\nNETDATA_CLAIM_ROOMS=%s\nOPENOBSERVE_INGEST_USER=%s\nOPENOBSERVE_INGEST_PASSWORD=%s\nCF_ACCESS_SIEM_CLIENT_ID=%s\nCF_ACCESS_SIEM_CLIENT_SECRET=%s\n' \
            "$TUNNEL_TOKEN" "$NETDATA_CLAIM_TOKEN" "$NETDATA_CLAIM_ROOMS" \
            "$OPENOBSERVE_INGEST_USER" "$OPENOBSERVE_INGEST_PASSWORD" \
            "$CF_ACCESS_SIEM_CLIENT_ID" "$CF_ACCESS_SIEM_CLIENT_SECRET" | \
            ssh -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" \
            'umask 077 && cat > /opt/stacks/vps01/.env'
```

- [ ] **Step 3: vps02 `.env`** — add `OPENOBSERVE_ROOT_EMAIL`, `OPENOBSERVE_ROOT_PASSWORD`, `OPENOBSERVE_INGEST_USER`, `OPENOBSERVE_INGEST_PASSWORD` (no CF values: vps02 posts to localhost).

```yaml
        env:
          TUNNEL_TOKEN: ${{ secrets.CLOUDFLARE_TUNNEL_TOKEN_VPS02_METRICS }}
          NETDATA_CLAIM_TOKEN: ${{ secrets.NETDATA_CLAIM_TOKEN }}
          NETDATA_CLAIM_ROOMS: ${{ secrets.NETDATA_CLAIM_ROOMS }}
          OPENOBSERVE_ROOT_EMAIL: ${{ secrets.OPENOBSERVE_ROOT_EMAIL }}
          OPENOBSERVE_ROOT_PASSWORD: ${{ secrets.OPENOBSERVE_ROOT_PASSWORD }}
          OPENOBSERVE_INGEST_USER: ${{ secrets.OPENOBSERVE_INGEST_USER }}
          OPENOBSERVE_INGEST_PASSWORD: ${{ secrets.OPENOBSERVE_INGEST_PASSWORD }}
        run: |
          # One file, one write: this is 'cat >', not '>>', so every value
          # the stack needs has to be printed here or it is lost.
          printf 'CLOUDFLARE_TUNNEL_TOKEN_VPS02_METRICS=%s\nNETDATA_CLAIM_TOKEN=%s\nNETDATA_CLAIM_ROOMS=%s\nOPENOBSERVE_ROOT_EMAIL=%s\nOPENOBSERVE_ROOT_PASSWORD=%s\nOPENOBSERVE_INGEST_USER=%s\nOPENOBSERVE_INGEST_PASSWORD=%s\n' \
            "$TUNNEL_TOKEN" "$NETDATA_CLAIM_TOKEN" "$NETDATA_CLAIM_ROOMS" \
            "$OPENOBSERVE_ROOT_EMAIL" "$OPENOBSERVE_ROOT_PASSWORD" \
            "$OPENOBSERVE_INGEST_USER" "$OPENOBSERVE_INGEST_PASSWORD" | \
            ssh -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" \
            'umask 077 && cat > /opt/stacks/vps02/.env'
```

- [ ] **Step 4: Verify steps**

In all three `Verify vpsNN` scripts, after the `echo "ok   cloudflared"` line, add:

```sh
            running=$(docker inspect -f "{{.State.Running}}" \
              vector 2>/dev/null || echo missing)
            [ "$running" = true ] || { echo "FAIL vector: $running"; exit 1; }
            echo "ok   vector"
```

In vps02's only, also add before the `running=` lines:

```sh
            probe openobserve http://127.0.0.1:5080/healthz
```

- [ ] **Step 5: Lint**

```sh
actionlint .github/workflows/deploy.yml && yamllint --strict .github/workflows/deploy.yml && echo OK
```
Expected: `OK`. What would have caught a missing `.env` line: nothing before the node — which is why the `printf` comment exists. Re-read each `printf` format against its argument list: seven `%s`, seven arguments on vps00.

- [ ] **Step 6: Commit**

```sh
git add .github/workflows/deploy.yml
git commit -m "feat(deploy): plumb OpenObserve and Access service-token secrets; verify vector and openobserve"
```

---

### Task 5: setup-maintenance.sh — journald log driver, 1G journal

**Files:**
- Modify: `scripts/setup-maintenance.sh` (the `docker log-opts` block and the `journald` block)

- [ ] **Step 1: Replace the docker block**

Replace everything from `# --- docker log-opts` to the matching `fi` (the `else echo "docker not installed..."` one) with:

```sh
# --- docker log driver: journald ---
# Container stdout goes to the systemd journal so Vector
# (stacks/<node>/vector.yaml) reads one source and needs no docker.sock.
# journald rejects json-file's max-size/max-file log-opts and dockerd
# refuses to start with unknown opts, so the whole block is rewritten,
# never merged. Three known shapes are handled; anything else is left
# alone with a warning, same as harden-node.sh's "ip" check.
if command -v docker >/dev/null 2>&1; then
  want='{
  "ip": "127.0.0.1",
  "log-driver": "journald"
}'
  have=$(tr -d '[:space:]' < /etc/docker/daemon.json 2>/dev/null || true)
  case "$have" in
    '{"ip":"127.0.0.1","log-driver":"journald"}')
      echo "daemon.json already uses the journald log driver, leaving it alone" ;;
    ''|'{"ip":"127.0.0.1"}'|'{"ip":"127.0.0.1","log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3"}}')
      printf '%s\n' "$want" > /etc/docker/daemon.json
      echo "set log-driver journald in daemon.json -- takes effect for containers created after the next Docker restart" ;;
    *)
      echo "WARNING: /etc/docker/daemon.json has unexpected content --" >&2
      echo "set \"log-driver\": \"journald\" by hand and drop json-file log-opts." >&2 ;;
  esac
else
  echo "docker not installed, skipping log driver"
fi
```

- [ ] **Step 2: Replace the journald block**

```sh
# --- journald: cap disk use, restart to apply (safe, no container impact) ---
# 1G, not 200M: container stdout lands here now (log driver above).
if grep -q '^SystemMaxUse=1G$' /etc/systemd/journald.conf 2>/dev/null; then
  echo "journald.conf already caps SystemMaxUse at 1G, leaving it alone"
else
  if grep -q '^#\?SystemMaxUse=' /etc/systemd/journald.conf; then
    sed -i 's/^#\?SystemMaxUse=.*/SystemMaxUse=1G/' /etc/systemd/journald.conf
  else
    echo 'SystemMaxUse=1G' >> /etc/systemd/journald.conf
  fi
  systemctl restart systemd-journald
  echo "capped journald at 1G and restarted it"
fi
```

- [ ] **Step 3: Update the header comment**

Replace the first paragraph of the file header so it reads: caps journald (1G), switches Docker's log driver to journald, weekly prune, unattended upgrades; keep the "never restarts Docker" paragraph verbatim.

- [ ] **Step 4: Lint and trace idempotency**

```sh
shellcheck -s sh scripts/setup-maintenance.sh && echo OK
```
Trace: second run hits the first `case` arm and the `already caps` branch — no writes. The real two-run check happens on a node in Task 9.

- [ ] **Step 5: Commit**

```sh
git add scripts/setup-maintenance.sh
git commit -m "feat(setup-maintenance): journald log driver for containers, 1G journal cap"
```

---

### Task 6: install-aide.sh

**Files:**
- Create: `scripts/install-aide.sh`

- [ ] **Step 1: Write the script**

```sh
#!/bin/sh
# Idempotent. Installs AIDE, builds the baseline once, and replaces
# Debian's daily timer (which emails root on a box with no mail) with a
# cron job that runs `aide --update`, pipes the report into the journal
# under SYSLOG_IDENTIFIER=aide, then adopts the new database. Every
# change is therefore reported exactly once, in OpenObserve, and becomes
# tomorrow's baseline: this is a change log, not a tamper lock.
#
# Usage: scripts/install-aide.sh <host>
#   scripts/install-aide.sh 203.0.113.10
#   Real addresses live in infra/inventory.yaml (gitignored).
#
# First run builds the database: a few minutes of CPU on a 2 vCPU node.

set -eu

host="${1:?usage: install-aide.sh <host>}"
ssh_port="${SSH_PORT:-22}"
ssh_user="${SSH_USER:-root}"

echo "Installing AIDE on ${ssh_user}@${host}:${ssh_port} ..."

# shellcheck disable=SC2087
ssh -p "$ssh_port" "${ssh_user}@${host}" 'sh -s' <<'EOF'
set -eu

if command -v aide >/dev/null 2>&1; then
  echo "aide already installed, leaving it alone"
else
  apt-get -qq update >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get -y -qq install aide aide-common >/dev/null
  echo "installed aide"
fi

# Debian's own daily check mails root; nothing here delivers mail.
if systemctl is-enabled dailyaidecheck.timer >/dev/null 2>&1; then
  systemctl disable --now dailyaidecheck.timer >/dev/null 2>&1
  echo "disabled dailyaidecheck.timer (mails root, no mail here)"
else
  echo "dailyaidecheck.timer already disabled, leaving it alone"
fi

if [ -f /var/lib/aide/aide.db ]; then
  echo "aide.db exists, leaving the baseline alone"
else
  echo "building the AIDE baseline (minutes) ..."
  nice -n 19 aideinit -y -f >/dev/null
  echo "built /var/lib/aide/aide.db"
fi

runner='#!/bin/sh
# Written by scripts/install-aide.sh. Check, log, adopt.
set -u
nice -n 19 aide.wrapper --update 2>&1 | logger -t aide
if [ -f /var/lib/aide/aide.db.new ]; then
  mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db
fi'
if [ -f /usr/local/sbin/aide-daily ] && [ "$(cat /usr/local/sbin/aide-daily)" = "$runner" ]; then
  echo "/usr/local/sbin/aide-daily already set, leaving it alone"
else
  printf '%s\n' "$runner" > /usr/local/sbin/aide-daily
  chmod 755 /usr/local/sbin/aide-daily
  echo "wrote /usr/local/sbin/aide-daily"
fi

cron_line='30 4 * * * root /usr/local/sbin/aide-daily'
if [ -f /etc/cron.d/aide-daily ] && grep -qF "$cron_line" /etc/cron.d/aide-daily; then
  echo "/etc/cron.d/aide-daily already set, leaving it alone"
else
  printf '%s\n' "$cron_line" > /etc/cron.d/aide-daily
  chmod 644 /etc/cron.d/aide-daily
  echo "wrote /etc/cron.d/aide-daily -- daily 04:30"
fi

echo "AIDE setup complete on $(hostname)"
EOF

echo "Done."
```

- [ ] **Step 2: Lint**

```sh
chmod +x scripts/install-aide.sh && shellcheck -s sh scripts/install-aide.sh && echo OK
```
Expected `OK`. Idempotency trace: every block has an "already" branch; the node run in Task 9 proves it.

- [ ] **Step 3: Commit**

```sh
git add scripts/install-aide.sh
git commit -m "feat(scripts): install-aide.sh -- daily file-integrity report into the journal"
```

---

### Task 7: Docs, rails, spec amendment

**Files:**
- Modify: `stacks/CLAUDE.md`, `scripts/CLAUDE.md`, `.claude/CLAUDE.md`, `README.md`, `docs/superpowers/specs/2026-08-22-siem-openobserve-design.md`
- Modify (memory, outside the repo): `~/.claude/projects/-Users-excollado-claude-projects-homelab-but-the-home-is-silent/memory/cloudflare-blocks-non-ph-traffic.md`

- [ ] **Step 1: `stacks/CLAUDE.md`**
  - Hostname list: after the `vps02-metrics` bullet add two bullets: `siem.maybeit.work` → `http://localhost:5080` on vps02, same tunnel, Access app `siem`, `owner email allow`, PH-only; `siem-ingest.maybeit.work` → same origin, Access app `siem-ingest`, one service-auth policy for the `siem-ingest` token, exempt from the geo rule (the nodes are US-hosted), still 403 without the token. Change "Six hostnames are live" to "Eight".
  - Service-token note: the `status-worker` token opens the three `*-metrics` apps; the `siem-ingest` token opens `siem-ingest` and nothing else. Never cross them.
  - New short section `## Logs (OpenObserve + Vector)`: what runs where, "no docker.sock — container logs come via the journald driver", `vector.yaml` identical on all nodes and enforced by `check-rails.sh`, caps hedged, retention 30d, not backed up.
- [ ] **Step 2: `scripts/CLAUDE.md`** — update the `setup-maintenance.sh` entry (journald driver, `SystemMaxUse=1G`), add `install-aide.sh` entry, and a failure-log line: "journald rejects json-file's `max-size`/`max-file` opts and dockerd will not start with unknown log-opts — rewrite `daemon.json` whole, never merge a driver change into existing opts."
- [ ] **Step 3: Root `.claude/CLAUDE.md`** — rail 1 sweep list `22/80/443/2377/3000/5080/19999`; "When" paragraph: three workloads live (Netdata, booking/ezBookkeeping, OpenObserve); directory map unchanged.
- [ ] **Step 4: `README.md`** — vps02 row: `Dokploy Remote Server, Netdata + OpenObserve logs + own cloudflared`; scripts list gains `install-aide.sh`; the `setup-maintenance.sh` line mentions the journald driver.
- [ ] **Step 5: Spec** — secrets table: replace the `OPENOBSERVE_INGEST_AUTH` row with `OPENOBSERVE_INGEST_USER` / `OPENOBSERVE_INGEST_PASSWORD` (Vector's basic auth takes user and password, not a pre-encoded value).
- [ ] **Step 6: Memory file** — add `siem-ingest.maybeit.work` to the exemption note (the rule expression gains `and http.host ne "siem-ingest.maybeit.work"`), dated 2026-08-22, "pending until Task 10 is done".
- [ ] **Step 7: The loop**

```sh
pre-commit run --all-files
shellcheck scripts/*.sh
git ls-files '*CLAUDE.md' | xargs wc -l
```
Expected: all green; every `CLAUDE.md` under ~500 lines.

- [ ] **Step 8: Commit and open the PR**

```sh
git add -A && git commit -m "docs: OpenObserve log stack -- hostnames, rails, scripts, README"
git push -u origin feat/siem-openobserve
gh pr create --title "feat: SIEM-ish log centralisation on vps02 (OpenObserve + Vector)" --body-file - <<'EOF'
Implements docs/superpowers/specs/2026-08-22-siem-openobserve-design.md.

- vps02: OpenObserve (127.0.0.1:5080) + Vector; vps00/vps01: Vector, posting via siem-ingest.maybeit.work
- Docker log driver -> journald (setup-maintenance.sh); journald cap 1G
- scripts/install-aide.sh: daily AIDE report into the journal
- deploy.yml: six new secrets into .env, verify vector + openobserve
- check-rails.sh: vector.yaml identical on all nodes; sweep list gains 5080

Needs before merge: six GitHub secrets, Cloudflare Access/tunnel/geo changes, setup-maintenance.sh + install-aide.sh run on all nodes (plan Tasks 8-10).

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01CgbAGZmfjFWWSNyWR7afS7
EOF
```
Hand Ex the PR link directly.

---

### Task 8: GitHub secrets (Ex)

- [ ] Ex creates, at `https://github.com/<owner>/homelab-but-the-home-is-silent/settings/secrets/actions`: `OPENOBSERVE_ROOT_EMAIL`, `OPENOBSERVE_ROOT_PASSWORD` (long random), `OPENOBSERVE_INGEST_USER` = same email as root for now, `OPENOBSERVE_INGEST_PASSWORD` = same as root for now (rotated in Task 12), `CF_ACCESS_SIEM_CLIENT_ID`, `CF_ACCESS_SIEM_CLIENT_SECRET` (from Task 10 step 1 — do Task 10 first if convenient).
- [ ] Verify names only: `gh secret list | grep -E 'OPENOBSERVE|CF_ACCESS_SIEM'` shows six rows. Values never printed.

---

### Task 9: Node provisioning, as root from the laptop

- [ ] `ssh-add ~/.ssh/id_ed25519_vps` (scripts pass no `-i`).
- [ ] For each of `vps00-root`, `vps01-root`, `vps02-root`: `scripts/setup-maintenance.sh <alias>` twice. Second run must print only "already ... leaving it alone" lines.
- [ ] For each: `scripts/install-aide.sh <alias>` twice. First run builds the baseline; second prints only "already" lines.
- [ ] Restart Docker on each node so the driver applies to newly created containers: `ssh vps0N-root 'systemctl restart docker'`. On vps00 this restarts the Dokploy control plane and Traefik for some seconds; on vps01 booking and budget blip. Tell Ex before doing it.
- [ ] Confirm on one node: `ssh vps02-root 'docker info --format "{{.LoggingDriver}}"'` prints `journald`.

---

### Task 10: Cloudflare (Claude drives the browser; Ex acts where it needs him)

Order matters: the service token first (its secret is shown once), then the Access apps, then the hostnames, then the geo rule.

- [ ] **Step 1: Service token** — Zero Trust → Access → Service Auth → Service Tokens → Create: name `siem-ingest`, duration longest offered. Ex copies Client ID and Client Secret straight into the two GitHub secrets (Task 8). The secret is shown once; Claude does not read it aloud or into chat.
- [ ] **Step 2: Access app `siem-ingest`** — Access → Applications → Add → Self-hosted: name `siem-ingest`, domain `siem-ingest.maybeit.work`, session 24h. One policy: name `service token`, action **Service Auth**, include → Service Token → `siem-ingest`.
- [ ] **Step 3: Access app `siem`** — Self-hosted: name `siem`, domain `siem.maybeit.work`, session 24h. One policy: name `owner email allow`, action Allow, include → Emails → Ex's email (copy the `budget` app's policy).
- [ ] **Step 4: Public hostnames** — Networks → Tunnels → vps02's tunnel → Public Hostname → Add, twice: `siem` → `http://localhost:5080`; `siem-ingest` → `http://localhost:5080`.
- [ ] **Step 5: Geo rule** — Security → WAF → Custom rules → `Block non-local traffic` → Edit expression to
  `(ip.src.country ne "PH" and http.host ne "maybeit.work" and http.host ne "siem-ingest.maybeit.work")` → Deploy. Ex confirms before Deploy; this is a security-rule edit.
- [ ] **Step 6: Verify through the read-only MCP servers, not by assumption**: `cfd_tunnel/{id}/configurations` for vps02's tunnel lists `vps02-metrics`, `siem`, `siem-ingest`; connector list still one `client_id`; the two Access apps exist with one policy each; the custom rule expression reads as above.

---

### Task 11: Merge, deploy, verify

- [ ] Ex merges the PR (link from Task 7). `deploy.yml` runs; Ex approves the `production` gate: hand the run URL directly.
- [ ] In Dokploy (`https://dokploy.maybeit.work`), Redeploy `booking` and `ezbookkeeping` so they are recreated on the journald driver. Seconds of downtime on vps01.
- [ ] On each node: `ssh vps0N-root 'logger -t siem-test "hello from $(hostname)"'`. In `https://siem.maybeit.work` → Logs → stream `journal`, query `SYSLOG_IDENTIFIER = 'siem-test'`: three lines, `node` field `vps00`/`vps01`/`vps02`, within a minute.
- [ ] Same view: filter `CONTAINER_NAME = 'cloudflared-vps02'` shows startup lines (container logs flow).
- [ ] Off-node sweep from the laptop: `for p in 22 80 443 2377 3000 5080 19999; do nc -z -w 3 <ip> $p && echo "open $p"; done` per node, real IPs from `infra/inventory.yaml`, output in chat with IPs redacted. Only `open 22` may print.
- [ ] From a PH client: `curl -sI https://siem-ingest.maybeit.work/ | head -1` is 403 or 302, never 200; `curl -sI https://siem.maybeit.work/ | head -1` is a 302 to `old-firefly-996b.cloudflareaccess.com`.
- [ ] Measure, don't infer: `ssh vps02-root 'docker stats --no-stream openobserve vector'` after an hour of ingest; record the numbers in `stacks/CLAUDE.md` next to the caps in the same turn.

---

### Task 12: Dedicated ingest user, rotate

- [ ] In OpenObserve UI → IAM → Users → Add: email `ingest@maybeit.work` (any address, it is a label), role `Editor` is not needed — pick the least role that can ingest (`Editor` if the UI offers nothing narrower on this version; note which it was).
- [ ] Ex updates GitHub secrets `OPENOBSERVE_INGEST_USER` / `OPENOBSERVE_INGEST_PASSWORD` to the new user, re-runs `deploy.yml` via `workflow_dispatch` (link), approves.
- [ ] Repeat the `logger -t siem-test` check on one node; lines still arrive.
- [ ] Note in `stacks/CLAUDE.md` that root creds are for the UI only and ingest uses the dedicated user.
