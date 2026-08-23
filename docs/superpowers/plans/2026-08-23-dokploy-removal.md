# Dokploy Removal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the Dokploy control plane from all three nodes, moving
`booking` and `ezbookkeeping` into `stacks/vps01/` where `deploy.yml` owns
them, and free ~848 MiB on vps00.

**Architecture:** The two apps join vps01's existing Compose stack with
their current volumes declared `external: true`, each publishing its own
loopback port from the block scheme -- no reverse proxy; `cloudflared`
dials the ports directly. Cutover is zero-downtime: the new containers come
up and are verified while Dokploy still serves `:80`, and the tunnel's
ingress is flipped before anything is deleted.

**Tech Stack:** Docker Compose (classic keys, rail 4), Cloudflare Tunnel,
GitHub Actions, POSIX `sh`.

**Port scheme:** `8NXX` -- `N` is the node (0/1/2), `XX01-XX49` apps,
`XX50-XX99` tools. This plan assigns `8101` booking and `8102` budget.
Moving `19999` and `5080` onto the scheme is follow-on work, one PR per
service; see the spec.

**Spec:** `docs/superpowers/specs/2026-08-23-dokploy-removal-design.md`

## Global Constraints

- **Rail 1:** no new inbound ports. Every published port binds
  `127.0.0.1`. `daemon.json` already forces this; do not rely on it alone,
  write the bind explicitly.
- **Rail 3:** `network_mode: host` on every `cloudflared` service.
- **Rail 4:** explicit `mem_limit`/`mem_reservation` on every app service.
  Classic Compose keys only; a `deploy:` block fails `check-rails.sh`.
- **Rail 5:** no real IPs in tracked files.
- **Rail 11:** never print secret material. Compare lengths, not values.
- **Rail 12:** rollback is `git revert` + push.
- Every task ends green on `pre-commit run --all-files`.
- Existing container and volume names are **frozen**: `booking-ptpwn8-mysql-1`,
  `ezbookkeeping`, `booking-ptpwn8_mysql-data`,
  `vps01booking-ezbookkeeping-rqdyxo_data`,
  `vps01booking-ezbookkeeping-rqdyxo_storage`.
- Node access is via the `vps0N-root` SSH aliases.

---

### Task 1: Rescue the secrets Dokploy holds (Ex, blocking)

Nothing else may start until this is done. The MySQL root and app
passwords are baked into the existing MySQL volume; losing them turns a
migration into a restore.

The GitHub secret names are **not** the names Dokploy uses. They follow the
repo convention `<OWNER>_<THING>[_VPS0N]`, where the owner is the hostname
the workload serves. The container's own variable names are unchanged --
the MySQL image requires `MYSQL_ROOT_PASSWORD` inside the container -- only
the value's source is renamed.

**Files:** none (GitHub Secrets only)

**Interfaces:**
- Produces: GitHub secrets `BOOKING_MYSQL_ROOT_PASSWORD`,
  `BOOKING_MYSQL_APP_PASSWORD`, `BUDGET_SECRET_KEY`, consumed by Task 4's
  `deploy.yml` changes.

- [ ] **Step 1: Read the values out of Dokploy**

In `https://dokploy.maybeit.work` open the `booking` Compose app →
Environment tab. Copy `MYSQL_ROOT_PASSWORD` and `DB_PASSWORD`. Then open
`ezbookkeeping` → Environment and copy `EBK_SECURITY_SECRET_KEY`.

- [ ] **Step 2: Store them as GitHub secrets**

At `https://github.com/nineW0nW0n/homelab-but-the-home-is-silent/settings/secrets/actions`
create these three, with those exact values. Do not regenerate them.

| Dokploy's name | GitHub secret |
|---|---|
| `MYSQL_ROOT_PASSWORD` | `BOOKING_MYSQL_ROOT_PASSWORD` |
| `DB_PASSWORD` | `BOOKING_MYSQL_APP_PASSWORD` |
| `EBK_SECURITY_SECRET_KEY` | `BUDGET_SECRET_KEY` |

- [ ] **Step 3: Verify names only, never values**

```sh
gh secret list | grep -E 'BOOKING_MYSQL_ROOT_PASSWORD|BOOKING_MYSQL_APP_PASSWORD|BUDGET_SECRET_KEY'
```

Expected: three rows.

- [ ] **Step 4: Confirm the deploy guard will accept them**

The `approve` job rejects a secret containing `# $ " ' \` or a backtick.
If any of the three contains one, the deploy fails closed before touching a
node. `EBK_SECURITY_SECRET_KEY` may be regenerated freely if it trips the
guard (it only invalidates sessions). **The two MySQL passwords may
not** -- if either trips it, stop and raise it: the password must be
changed inside MySQL first, which is a separate procedure.

---

### Task 2: Prove the volumes adopt cleanly, on a throwaway copy

Before editing the real stack, prove `external: true` adopts existing data
rather than creating empty volumes. This is the one failure that would cost
real customer data.

**Files:** none tracked (scratch on vps01)

**Interfaces:**
- Consumes: nothing.
- Produces: a verified assumption for Task 3's compose file.

- [ ] **Step 1: Record the baseline**

```sh
ssh vps01-root 'docker exec booking-ptpwn8-mysql-1 sh -c \
  "mysql -uroot -p\$MYSQL_ROOT_PASSWORD -N -B \
   -e \"SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=DATABASE();\" \
   \$MYSQL_DATABASE; \
   mysql -uroot -p\$MYSQL_ROOT_PASSWORD -N -B -e \"SELECT COUNT(*) FROM ea_users;\" \
   \$MYSQL_DATABASE" 2>/dev/null'
```

Expected: `14` then `4`. Write both numbers down; Task 6 asserts them again.

- [ ] **Step 2: Prove adoption with a read-only probe**

```sh
ssh vps01-root 'docker run --rm -v booking-ptpwn8_mysql-data:/d:ro alpine:3.21 \
  sh -c "ls /d | head -5; ls /d/easyappointments | wc -l"'
```

Expected: MySQL system files (`ibdata1`, `mysql`, …) and a non-zero count
of table files. A volume Compose would have created fresh is empty; this
proves the name in the compose file resolves to the populated one.

- [ ] **Step 3: Commit nothing**

This task changes no files. It exists so Task 3 is written against a
verified fact rather than an assumption.

---

### Task 3: Add both apps to vps01's stack

No reverse proxy. Each app publishes its own loopback port from the block
scheme and `cloudflared` dials it directly.

**Files:**
- Modify: `stacks/vps01/docker-compose.yml`

**Interfaces:**
- Consumes: Task 1's secret names.
- Produces: services `easyappointments` (on `127.0.0.1:8101`), `mysql`,
  `ezbookkeeping` (on `127.0.0.1:8102`); network `apps`; external volumes
  as named in Global Constraints.

- [ ] **Step 1: Add the services to the stack**

In `stacks/vps01/docker-compose.yml`, add these services after `vector` and
before the `volumes:` block. Ports follow the scheme in the spec: `81xx` is
vps01, `xx01-xx49` is apps.

```yaml
  easyappointments:
    image: alextselegidis/easyappointments:1.6.0
    container_name: booking-ptpwn8-easyappointments-1
    restart: unless-stopped
    depends_on:
      - mysql
    entrypoint:
      - sh
      - -c
      - |
        echo 'ServerName booking.maybeit.work' >> /etc/apache2/apache2.conf
        exec /usr/local/bin/docker-entrypoint.sh
    environment:
      BASE_URL: https://booking.maybeit.work
      DEBUG_MODE: "FALSE"
      DB_HOST: mysql
      DB_NAME: easyappointments
      DB_USERNAME: easyappointments
      DB_PASSWORD: ${BOOKING_MYSQL_APP_PASSWORD}
      MAIL_PROTOCOL: mail
      MAIL_SMTP_DEBUG: "0"
      MAIL_SMTP_AUTH: "0"
      MAIL_SMTP_HOST: smtp.example.org
      MAIL_SMTP_USER: ""
      MAIL_SMTP_PASS: ""
      MAIL_SMTP_CRYPTO: tls
      MAIL_SMTP_PORT: "587"
      MAIL_FROM_ADDRESS: booking@maybeit.work
      MAIL_FROM_NAME: maybeit.work Booking
      MAIL_REPLY_TO_ADDRESS: booking@maybeit.work
    # Rail 1: loopback only. cloudflared runs network_mode: host, so
    # 127.0.0.1:8101 is reachable to it and to nothing off-node. The bind
    # address is written explicitly rather than relying on daemon.json's
    # default -- a config you authored is no proof the daemon honoured it.
    ports:
      - "127.0.0.1:8101:80"
    networks:
      - apps
    mem_limit: 256m
    mem_reservation: 128m

  mysql:
    image: mysql:8.0
    container_name: booking-ptpwn8-mysql-1
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: ${BOOKING_MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: easyappointments
      MYSQL_USER: easyappointments
      MYSQL_PASSWORD: ${BOOKING_MYSQL_APP_PASSWORD}
    volumes:
      - booking-mysql-data:/var/lib/mysql
    networks:
      - apps
    mem_limit: 640m
    mem_reservation: 320m

  ezbookkeeping:
    image: mayswind/ezbookkeeping:1.6.1
    container_name: ezbookkeeping
    restart: unless-stopped
    environment:
      EBK_SERVER_DOMAIN: budget.maybeit.work
      EBK_SERVER_ROOT_URL: https://budget.maybeit.work/
      EBK_SERVER_ENABLE_GZIP: "true"
      EBK_DATABASE_TYPE: sqlite3
      EBK_DATABASE_DB_PATH: /ezbookkeeping/data/ezbookkeeping.db
      EBK_LOG_MODE: console
      EBK_USER_MAX_TRANSACTION_PICTURE_SIZE: "10485760"
      EBK_USER_ENABLE_REGISTER: "false"
      EBK_SECURITY_SECRET_KEY: ${BUDGET_SECRET_KEY}
    volumes:
      - ezbookkeeping-data:/ezbookkeeping/data
      - ezbookkeeping-storage:/ezbookkeeping/storage
      - /etc/localtime:/etc/localtime:ro
    # Rail 1: loopback only, same reasoning as easyappointments above.
    ports:
      - "127.0.0.1:8102:8080"
    networks:
      - apps
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    mem_limit: 256m
    mem_reservation: 128m
```

- [ ] **Step 3: Declare the external volumes and the network**

Replace the `volumes:` block at the end of the file with:

```yaml
volumes:
  netdataconfig:
  netdatalib:
  netdatacache:
  vector-data:
  # Adopted, not created. The names are Dokploy's and are deliberately
  # frozen: backup-booking.sh and backup-ezbookkeeping.sh hardcode them,
  # and a rename starts MySQL on an empty database (see dokploy/CLAUDE.md).
  # external: true makes Compose refuse to run rather than silently create
  # an empty volume if the name is ever wrong.
  booking-mysql-data:
    external: true
    name: booking-ptpwn8_mysql-data
  ezbookkeeping-data:
    external: true
    name: vps01booking-ezbookkeeping-rqdyxo_data
  ezbookkeeping-storage:
    external: true
    name: vps01booking-ezbookkeeping-rqdyxo_storage

networks:
  apps:
```

- [ ] **Step 4: Validate the compose file**

Laptop has no Docker. Copy to vps02 (which runs nothing from vps01) and
validate there. Use `tar`, not `rsync` -- macOS rsync stalls against these
nodes with `poll: timeout`.

```sh
ssh vps02-root 'mkdir -p /root/.v1check'
tar cz -C stacks vps01 | ssh vps02-root 'tar xz -C /root/.v1check'
ssh vps02-root 'cd /root/.v1check/vps01 && \
  for v in CLOUDFLARE_TUNNEL_TOKEN_VPS01_BOOKING NETDATA_CLAIM_TOKEN \
           NETDATA_CLAIM_ROOMS OPENOBSERVE_INGEST_USER OPENOBSERVE_INGEST_PASSWORD \
           CF_ACCESS_SIEM_CLIENT_ID CF_ACCESS_SIEM_CLIENT_SECRET \
           BOOKING_MYSQL_ROOT_PASSWORD BOOKING_MYSQL_APP_PASSWORD \
           BUDGET_SECRET_KEY; do \
    echo "$v=x"; done > .env && \
  docker compose config --quiet && echo "compose config OK"'
ssh vps02-root 'rm -rf /root/.v1check'
```

Expected: `compose config OK`. External volumes are not checked by
`config`, only at `up` time -- that is Task 5's job.

- [ ] **Step 5: Run the repo checks**

```sh
pre-commit run --all-files
```

Expected: all green, including `hard rails` (rail 4 wants `mem_limit` on
every new service, and fails on a `deploy:` block).

- [ ] **Step 6: Commit**

```sh
git add stacks/vps01/docker-compose.yml
git commit -m "feat(vps01): bring booking and ezbookkeeping into the stack"
```

---

### Task 4: Teach deploy.yml the three new secrets

**Files:**
- Modify: `.github/workflows/deploy.yml` (the `deploy-vps01` `.env` step,
  and the `approve` guard's name list)

**Interfaces:**
- Consumes: Task 1's secrets, Task 3's `${...}` references.
- Produces: `/opt/stacks/vps01/.env` containing all ten keys.

- [ ] **Step 1: Add the secrets to the vps01 env block**

In `deploy-vps01`'s "Write remote .env" step, add to its `env:` mapping:

```yaml
          BOOKING_MYSQL_ROOT_PASSWORD: ${{ secrets.BOOKING_MYSQL_ROOT_PASSWORD }}
          BOOKING_MYSQL_APP_PASSWORD: ${{ secrets.BOOKING_MYSQL_APP_PASSWORD }}
          BUDGET_SECRET_KEY: ${{ secrets.BUDGET_SECRET_KEY }}
```

and to the piped `printf` group, one `printf` per key (120-col yamllint):

```sh
            printf 'BOOKING_MYSQL_ROOT_PASSWORD=%s\n' "$BOOKING_MYSQL_ROOT_PASSWORD"
            printf 'BOOKING_MYSQL_APP_PASSWORD=%s\n' "$BOOKING_MYSQL_APP_PASSWORD"
            printf 'BUDGET_SECRET_KEY=%s\n' "$BUDGET_SECRET_KEY"
```

- [ ] **Step 2: Add them to the dotenv-safety guard**

In the `approve` job's "Reject secrets a dotenv parser would mangle" step,
add the same three names to the `env:` mapping and to the `for name in`
list. A `#` in `BOOKING_MYSQL_APP_PASSWORD` would otherwise reach MySQL
truncated and fail authentication -- the exact failure this guard was built
for.

- [ ] **Step 3: Add the apps to the vps01 verify step**

In `Verify vps01`, alongside the existing checks:

```sh
            was_mysql=$(snap booking-ptpwn8-mysql-1)
            was_ezb=$(snap ezbookkeeping)
```

taken before the shared `sleep 75`, and after it:

```sh
            up booking-ptpwn8-mysql-1 "$was_mysql"
            up ezbookkeeping "$was_ezb"
```

Change the two existing app probes to go through the new port:

```sh
            probe booking http://127.0.0.1:8101/
            probe budget http://127.0.0.1:8102/
```

- [ ] **Step 4: Lint and commit**

```sh
pre-commit run --all-files
git add .github/workflows/deploy.yml
git commit -m "feat(ci): deploy booking and ezbookkeeping from stacks/vps01"
```

Expected: `actionlint` green. Remember the verify script runs inside
`ssh '...'` single quotes -- no apostrophes, no `'` in any added comment or
echo, or the script terminates early.

---

### Task 5: Deploy and cut over with the tunnel

**Not zero-downtime, corrected 2026-08-23.** The first draft said the new
containers come up alongside Dokploy's. They cannot: the container names
are frozen to the strings Dokploy's containers already hold, so `docker
compose up` fails with `Conflict. The container name ... is already in
use`, and even with different names two MySQL processes cannot share one
data volume. Dokploy's three containers on vps01 are removed (`docker rm
-f`, which leaves named volumes alone) immediately before the deploy is
approved, and the apps are down from that moment until `up -d` brings
them back on `:8101` and `:8102` and the tunnel is flipped -- a few
minutes. Dokploy's autodeploy is dead (the zone geo rule 403s GitHub's
webhook servers, `dokploy/CLAUDE.md`), so a push will not recreate them.

Sequence: merge, wait for the run to reach the `approve` gate, remove the
containers, approve, verify, flip the tunnel.

**Files:** none (deploy + Cloudflare)

**Interfaces:**
- Consumes: Tasks 3 and 4.
- Produces: `booking`/`budget` served directly from their own loopback
  ports, with Dokploy no longer in the request path.

- [ ] **Step 1: Open the PR and let Ex merge it**

Merging triggers `deploy.yml` (paths include `stacks/**`). The run stops at
the `production` gate. **Before Ex approves**, remove Dokploy's containers
on vps01 -- names only, volumes untouched:

```sh
ssh vps01-root 'docker rm -f booking-ptpwn8-easyappointments-1 \
  booking-ptpwn8-mysql-1 ezbookkeeping && docker volume ls -q | grep -c -E \
  "booking-ptpwn8_mysql-data|rqdyxo_(data|storage)"'
```

Expected: the three names echoed, then `3` -- all three volumes survived
the removal. Then Ex approves. Hand him the run URL directly.

The verify step's app probes should pass. They curl each app directly on
its new loopback port, so they test the new containers regardless of where
the tunnel still points. A failure here means an app is genuinely down --
read the FAIL line rather than assuming it is a cutover-ordering artefact.

No `Host:` header is needed now: without a proxy in front, each port serves
exactly one app.

- [ ] **Step 2: Assert the volumes were adopted, not recreated**

```sh
ssh vps01-root 'docker exec booking-ptpwn8-mysql-1 sh -c \
  "mysql -uroot -p\$MYSQL_ROOT_PASSWORD -N -B -e \
   \"SELECT COUNT(*) FROM ea_users;\" \$MYSQL_DATABASE" 2>/dev/null'
```

Expected: `4`. **A `0` means Compose created an empty volume: stop, do not
proceed, do not delete anything.** Restore from
`r2://homelab-backups/weekly/booking-mysql-*.sql.gz`.

- [ ] **Step 3: Verify both apps answer on their new ports**

```sh
ssh vps01-root 'for p in 8101 8102; do
  printf "%s " "$p"
  curl -s -o /dev/null -w "%{http_code}\n" "http://127.0.0.1:$p/"
done'
```

Expected: `200` twice. Dokploy's Traefik on `:80` is still serving live
traffic at this point; nothing user-facing has changed.

- [ ] **Step 4: Flip the tunnel ingress**

Read the current config first, then PUT the full ingress list with the two
app hostnames moved to their own ports, catch-all last. Via
`cloudflare-api`:

```js
async () => {
  const TUN = "8cfda853-c51e-444a-b903-892193f888ff"; // vps01-booking
  const cur = await cloudflare.request({ method: "GET",
    path: `/accounts/${accountId}/cfd_tunnel/${TUN}/configurations` });
  return cur.result.config.ingress; // read before writing
}
```

Then PUT the same list with `service` changed from `http://localhost:80`
to `http://localhost:8101` for `booking.maybeit.work` and to
`http://localhost:8102` for `budget.maybeit.work`, leaving
`vps01-metrics.maybeit.work` and the `http_status:404` catch-all
untouched.

This is the step the port scheme exists for: each hostname now names a
distinct origin port, so a route pointed at the wrong node fails with
connection-refused rather than returning 200 from the wrong service.

- [ ] **Step 5: Verify from the public side**

```sh
curl -s -o /dev/null -w "booking %{http_code}\n" https://booking.maybeit.work/
curl -s -o /dev/null -w "budget  %{http_code}\n" https://budget.maybeit.work/
```

Run from Ex's laptop, not a node: the zone geo rule 403s non-PH sources and
the nodes are US-hosted. Expected: `200` for booking, and for budget a
`302` to the Access login is also correct.

- [ ] **Step 6: Confirm the backups still work against the moved apps**

```sh
ssh vps01-root 'su - deploy -c "FORCE_BACKUP=1 /opt/stacks/vps01/backup-booking.sh"' | tail -3
ssh vps01-root 'su - deploy -c "FORCE_BACKUP=1 /opt/stacks/vps01/backup-ezbookkeeping.sh"' | tail -3
```

Expected: `done` from both, and fresh objects in R2. The scripts were never
edited; this proves the frozen names held.

---

### Task 6: Delete Dokploy

Only now, and only after Task 5 Step 2 returned `4`.

**Files:** none (nodes)

- [ ] **Step 1: Remove Dokploy's Traefik from vps01**

```sh
ssh vps01-root 'docker rm -f dokploy-traefik && \
  curl -s -o /dev/null -w "booking still 200: %{http_code}\n" \
  http://127.0.0.1:8101/'
```

- [ ] **Step 2: Remove the idle Traefiks from vps00 and vps02**

```sh
for n in vps00 vps02; do ssh $n-root 'docker rm -f dokploy-traefik'; done
```

These route nothing (verified in the spec); removing them is not a cutover.

- [ ] **Step 3: Remove the control plane from vps00**

```sh
ssh vps00-root 'docker service rm dokploy dokploy-postgres; \
  docker ps --format "{{.Names}}" | grep -i dokploy || echo "no dokploy containers"'
```

- [ ] **Step 4: Leave Swarm on all three**

```sh
for n in vps00 vps01 vps02; do
  ssh $n-root 'docker swarm leave --force >/dev/null 2>&1; \
    docker info --format "swarm: {{.Swarm.LocalNodeState}}"'
done
```

Expected: `swarm: inactive` three times. This also removes the
`DOCKER-INGRESS` chain that rail 1 notes UFW cannot see.

- [ ] **Step 5: Reclaim the disk and record the memory**

```sh
for n in vps00 vps01 vps02; do
  ssh $n-root 'docker system prune -af --volumes=false >/dev/null; \
    free -m | awk "/Mem:/ {printf \"used %sM of %sM\n\", \$3, \$2}"'
done
```

Expected: vps00 below 700 MB. Record the three figures; Task 8 writes them
into `stacks/CLAUDE.md` as measured values.

**`--volumes=false` is not optional.** The app volumes are `external`, and
a prune with volumes would be free to delete them.

- [ ] **Step 6: Remove exim4**

```sh
for n in vps00 vps01 vps02; do
  ssh $n-root 'systemctl disable --now exim4 >/dev/null 2>&1; \
    apt-get -y purge exim4 exim4-base exim4-config exim4-daemon-light >/dev/null 2>&1; \
    apt-get -y autoremove >/dev/null 2>&1; \
    systemctl is-active exim4 2>/dev/null || echo "exim4 gone"'
done
```

Nothing here sends mail: Netdata alerts go to Telegram and AIDE's mailing
timer was disabled for this reason.

---

### Task 7: Cloudflare and GitHub cleanup

**Files:** none (Cloudflare, GitHub)

- [ ] **Step 1: Delete the two Dokploy Access apps**

The `dokploy` app and the `dokploy` `/api/deploy` bypass app. List first,
delete by id, then re-list to confirm:

```js
async () => {
  const apps = await cloudflare.request({ method: "GET",
    path: `/accounts/${accountId}/access/apps`, query: { per_page: 50 } });
  return apps.result.map(a => ({ name: a.name, domain: a.domain, id: a.id }));
}
```

- [ ] **Step 2: Delete the `dokploy.maybeit.work` DNS record and tunnel route**

Remove the hostname from tunnel `677f272c-a06b-4543-bd93-7cd7393d5ef6`'s
ingress (keep `vps00-metrics` and the catch-all), then delete the CNAME.

- [ ] **Step 3: Delete the autodeploy WAF rule**

Rule `Dokploy autodeploy webhook` in ruleset
`3af69209b38c4ead846e30c6898e2bb8` exists only to let GitHub's webhook
reach `/api/deploy`. **This also frees the zone's single free rate-limit
rule**, which the failure log records as spent on that path.

- [ ] **Step 4: Delete the unused GitHub secret**

```sh
gh secret delete DOKPLOY_API_TOKEN
```

`.github/workflows/CLAUDE.md` records it as consumed by no workflow.

- [ ] **Step 5: Verify by reading back, not by assuming**

Re-list Access apps, the tunnel configs and the custom ruleset. Confirm
each tunnel still shows exactly one connector `client_id` (rail 2).

---

### Task 8: Repo and documentation cleanup

**Files:**
- Delete: `dokploy/` (whole directory, including `dokploy/CLAUDE.md`)
- Delete: `scripts/bootstrap-dokploy.sh`, `scripts/cap-dokploy-resources.sh`
- Modify: `.claude/CLAUDE.md`, `README.md`, `stacks/CLAUDE.md`,
  `stacks/vps01/CLAUDE.md`, `scripts/CLAUDE.md`,
  `.github/workflows/CLAUDE.md`, `.pre-commit-config.yaml` if it names
  removed scripts, `scripts/check-rails.sh` if it does

- [ ] **Step 1: Find every reference before deleting anything**

```sh
grep -rn -i 'dokploy' --exclude-dir=.git . | grep -v '^./docs/superpowers/' | wc -l
grep -rln -i 'dokploy' --exclude-dir=.git . | grep -v '^./docs/superpowers/'
```

Work the file list top to bottom. `docs/superpowers/` is history and stays
as written -- handoffs and old plans are records, not claims about today.

- [ ] **Step 2: Delete the directory and scripts**

```sh
git rm -r dokploy
git rm scripts/bootstrap-dokploy.sh scripts/cap-dokploy-resources.sh
```

- [ ] **Step 3: Update the directory map in root `CLAUDE.md`**

Remove the `dokploy/` row. Update the `stacks/vps01/` row to say it now
carries the two apps. Root's "How" line still says workloads deploy via
`deploy.yml` -- that is finally true without exception, so drop any
Dokploy caveat around it.

- [ ] **Step 4: Rewrite the README's deployment claim**

README currently describes Dokploy as part of the stack. It is the only
public document here, so a stale claim is made to strangers. State that
GitHub Actions deploys everything, with one approval, and that there is no
web control plane.

- [ ] **Step 5: Add the failure-log entries**

To `stacks/vps01/CLAUDE.md`:

```markdown
- **The app volumes are `external: true` and their names are frozen.**
  `booking-ptpwn8_mysql-data`, `vps01booking-ezbookkeeping-rqdyxo_data` and
  `..._storage` are Dokploy's old project-prefixed names, kept after Dokploy
  was removed because `backup-booking.sh` and `backup-ezbookkeeping.sh`
  hardcode them and because a rename starts MySQL on an empty database.
  `external: true` is what makes a wrong name fail loudly instead of
  silently creating an empty volume.
```

To `stacks/CLAUDE.md`, with the figures measured in Task 6 Step 5:

```markdown
- **Removing Dokploy freed <N> MB on vps00** (measured <date>): the control
  plane alone was 749.7 MiB of a 1966 MB node. Its Traefik on vps00 and
  vps02 routed nothing -- cloudflared went straight to `localhost:3000`,
  `:19999` and `:5080` -- so two of the three were pure overhead.
```

- [ ] **Step 6: Green the checks and commit**

```sh
pre-commit run --all-files
shellcheck -s sh scripts/*.sh
git ls-files '*CLAUDE.md' | xargs wc -l
git add -A
git commit -m "docs: retire Dokploy -- CI is now the only path to production"
```

Every `CLAUDE.md` must stay under ~500 lines; deleting `dokploy/CLAUDE.md`
removes 207.

---

### Task 9: Final verification

**Files:** none

- [ ] **Step 1: Run the spec's seven checks**

Each is a command, not a judgement:

```sh
curl -s -o /dev/null -w "booking %{http_code}\n" https://booking.maybeit.work/
curl -s -o /dev/null -w "budget  %{http_code}\n" https://budget.maybeit.work/
ssh vps01-root 'docker exec booking-ptpwn8-mysql-1 sh -c \
  "mysql -uroot -p\$MYSQL_ROOT_PASSWORD -N -B -e \
   \"SELECT COUNT(*) FROM ea_users;\" \$MYSQL_DATABASE" 2>/dev/null'
for n in vps00 vps01 vps02; do
  ssh $n-root 'docker ps --format "{{.Names}}" | grep -i dokploy || echo "clean"'
  ssh $n-root 'docker info --format "swarm: {{.Swarm.LocalNodeState}}"'
  ssh $n-root 'free -m | awk "/Mem:/ {printf \"used %sM of %sM\n\", \$3, \$2}"'
done
```

Expected: 200/200 (or 302 for budget behind Access), `4`, `clean` and
`swarm: inactive` three times, vps00 under 700 MB.

- [ ] **Step 2: Prove the logs still flow**

The apps were recreated, so their log driver is `journald` from birth:

```sh
ssh vps01-root 'for c in booking-ptpwn8-easyappointments-1 booking-ptpwn8-mysql-1 ezbookkeeping; do
  printf "%-30s %s\n" "$c" "$(docker inspect -f "{{.HostConfig.LogConfig.Type}}" "$c")"
done'
```

Expected: `journald` three times. Then confirm rows for `node = vps01`
reach OpenObserve, querying by `container_name`.

- [ ] **Step 3: Sweep the ports from off-node**

Rail 1 is only proven from outside. From Ex's laptop:

```sh
# Addresses come from infra/inventory.yaml (gitignored, rail 5) or the
# vps0N-root Host blocks in ~/.ssh/config. Run once per node.
for p in 22 80 443 2377 3000 5080 8080 19999; do
  nc -z -w 3 "$NODE_IP" "$p" && echo "$p OPEN" || echo "$p closed"
done
```

Expected: `22 OPEN`, everything else closed -- including the new `8080` and
the now-dead `3000`. **No `-G 3`**: that is BSD-only and Debian's netcat
exits 1 without connecting, making every port read closed.

- [ ] **Step 4: Write the handoff**

`docs/superpowers/handoff/2026-08-23-dokploy-removal.md`: what moved, the
measured before/after memory, the frozen names and why, and what a future
session must not "tidy up".
