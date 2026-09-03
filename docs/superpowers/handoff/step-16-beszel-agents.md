# HANDOFF: Beszel agents on vps00, vps01, vps02

TARGET REPO: homelab-but-the-home-is-silent (NOT this repo).
ISSUED BY: phoenixlab, docs/exec-plans/consolidation.md step 16.
AUDIENCE: an agent working in the homelab repo. Terse by intent.

## READ THIS FIRST — THIS SPEC IS WRITTEN FROM OUTSIDE YOUR REPO

It does not know your rails. Reconcile every block below against your
`.claude/CLAUDE.md` and run `scripts/check-rails.sh` before committing. Where
this spec and a rail conflict, THE RAIL WINS — amend the block and report the
conflict back rather than following this file.

Known reconciliations already applied, from your rails 1, 3 and 4:
  - rail 3 makes `network_mode: host` MANDATORY, not the vendor preference
    this spec originally called it. Section 4 item 2 still explains why it is
    also load-bearing for the firewall.
  - rail 4 requires mem_limit/mem_reservation. Added in section 1, from a
    measurement, not a guess. `deploy:` is not used — compose up ignores it.
  - rail 1 forbids opening an inbound port without asking. Section 2 opens
    one. The operator approved the SHAPE of it on 2026-09-02; you must
    still ask before running the command. Section 2.1 says how.

## GOAL

Each of vps00, vps01, vps02 runs a Beszel agent. A hub already running on the
Ashes node connects IN to each agent over SSH on tcp/45876. Agents never dial
out. Nothing is published to the internet, no DNS record is created, no
Cloudflare Access application is created, no tunnel ingress rule is added.

Netdata KEEPS RUNNING. This is additive. Retiring netdata is a later step and
is blocked on comparing alert behaviour, not on this one.

## DONE-WHEN

1. `docker ps` on each node shows a running beszel-agent container.
2. `ss -ltnp | grep 45876` on each node shows the agent listening.
3. `scripts/check-rails.sh` passes.

Those three are reachable without section 2 and are a complete, safe stopping
point. The two below need the firewall rule, which needs explicit permission:

4. From a host that is NOT the Ashes node, a TCP connect to <node>:45876 is
   refused or times out.
5. The hub operator confirms all three appear with live CPU/memory/disk.

## 1. COMPOSE BLOCK — add to stacks/vps00/, stacks/vps01/, stacks/vps02/

Add this service to each node's docker-compose.yml. Identical on all three.

```yaml
  beszel-agent:
    image: henrygd/beszel-agent:0.18.8
    restart: unless-stopped
    network_mode: host
    volumes:
      - beszel-agent-data:/var/lib/beszel-agent
    mem_limit: 128m
    mem_reservation: 32m
    environment:
      LISTEN: 45876
      KEY: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBhsAA+enUy8mR7+/mwhctM3PKNw9awWtIwhxLsfTBnU"
```

`mem_limit` is measured, not guessed: the same image on the Ashes node used
11.85 MiB resident after 30 minutes, WITH the Docker socket mounted. These
three agents do not get the socket and collect less, so 128m is roughly a
tenfold headroom on 1966 MB nodes that also carry 2047 MB of swap. The cap
exists to stop one service taking the node, not to make it slow.

Add to the `volumes:` block at the bottom of each file:

```yaml
  beszel-agent-data:
```

## 2. FIREWALL — APPROVED IN PRINCIPLE. YOU MUST STILL ASK BEFORE APPLYING.

### 2.1 Status of this decision

The operator was asked on 2026-09-02, in full knowledge that your rail 1 is
"no open inbound ports except SSH", and chose to proceed. That is a decision
about the SHAPE of the change. It is NOT standing permission to run the command
on a given node at a given moment.

**Before you run anything in 2.4, present section 2 to the operator and get an
explicit yes.** Your root brain requires asking before opening an inbound port;
an approval recorded in another repo's file does not discharge that. If the
answer is no, or you cannot get one, stop after sections 1 and 3 — that is a
correct and safe resting state, not a half-finished one.

### 2.2 Why an inbound port is needed at all

Beszel has two transports. Only one is usable here.

  agent dials hub (WebSocket)  — needs the agent to reach a hostname in the
    operator's zone. All three of these nodes report source country US, and
    that zone carries a WAF rule blocking every non-local country, evaluated
    BEFORE Cloudflare Access. The agent would be blocked, and the symptom
    presents as an authentication failure rather than a geographic one.
    Exempting a hostname to fix it would cut a permanent hole in the zone for
    the benefit of three nodes that are being decommissioned. Further: the
    agent's flags are -c -h -k -l -t -u -v — there is no way to send
    CF-Access-Client-Id/Secret headers, so such a hostname could not even be
    protected by a service token. It would be a genuinely public endpoint.

  hub dials agent (SSH)  — needs tcp/45876 open on each node, to one source.
    No hostname, no DNS record, no Access application, no WAF change, and
    nothing added to the zone that outlives these nodes.

The second is the lesser exposure. That is the whole argument.

### 2.3 What is actually exposed, and what limits it

  - ONE port, tcp/45876, on each of three nodes.
  - Reachable from ONE source address, the Ashes node. ufw's default-deny
    holds it closed to everything else.
  - The listener is an SSH server whose only credential is the hub's public
    key. The vendor states this design prevents command execution on the agent
    even if the hub's private key is compromised — it is not a shell.
  - No Docker socket is mounted in these agents (section 4 item 1), so a
    compromise of the listener does not reach the Docker API.
  - The exposure EXPIRES: these nodes are being cleared. The rule is deleted
    with them. Nothing is added to the zone, which outlives them.

Rail 1's existing enforcement does not cover this, and it is important to know
why before deciding. `DOCKER-USER ... -j DROP` and the `"ip": "127.0.0.1"`
default bind in daemon.json both act on Docker's NAT path, which is how
PUBLISHED ports reach a container. A `network_mode: host` service — which rail
3 requires — binds the host's interfaces directly and never traverses those
chains. For this listener ufw is the only enforcing layer that exists. This is
also why section 4 item 2 forbids "fixing" it to a published port: that would
move the listener under DOCKER-USER and make the ufw rule below silently inert
while looking more conventional.

### 2.4 The change, once permission is given

Per node, as root:

```
ufw allow from <ASHES_IP> to any port 45876 proto tcp comment 'beszel hub'
```

<ASHES_IP> is the `HostName` of the `Host ashes` block in ~/.ssh/config on the
operator's machine. DO NOT COMMIT IT to either repo. Never `ufw allow 45876`
without a source — that opens it to the internet.

Blast radius: adds one ufw rule per node. Removes nothing, restarts nothing,
touches no other rule, and changes no other node. Reversible by 2.6.

### 2.5 Prove the restriction, do not assume it

From a machine that is NOT the Ashes node:

```
nc -vz -w 5 <node> 45876     # MUST fail: refused or timeout
```

A success means the rule is missing or has no source restriction, and the port
is open to the internet. This negative test is the one that matters; the
positive case proves itself when the hub connects.

### 2.6 Rollback

```
ufw status numbered | grep 45876      # find the rule number
ufw delete <n>
```

Removing it makes the node invisible to the hub and changes nothing else.

## 2b. BEFORE COMMITTING ANYTHING

```
scripts/check-rails.sh
```

It must pass. It mechanically enforces rails 3 and 4 on every compose service,
which is where this spec was already wrong once.

## 3. VERIFY (run these, do not assume)

Per node:
```
docker ps --filter name=beszel-agent --format '{{.Names}} {{.Status}}'
ss -ltnp | grep 45876
docker logs beszel-agent 2>&1 | tail -5
ufw status numbered | grep 45876
```

Expected in logs: `Starting SSH server addr=45876 network=tcp`.
Expected and HARMLESS: `WARN Error creating WebSocket client err="HUB_URL
environment variable not set"`. Do not "fix" it — see DO NOT #4.

Negative test, from any machine other than the Ashes node:
```
nc -vz -w 5 <node> 45876     # must fail: refused or timeout
```
A success here means the ufw rule is missing or has no source restriction.

## 4. DO NOT

1. DO NOT mount /var/run/docker.sock into these agents. The Ashes agent has it;
   these three must not. They are the only agents accepting an inbound
   connection, and the socket is root-equivalent access to the host regardless
   of `:ro` — a client needs write permission to connect at all and the API
   stays fully usable. Host-level CPU/memory/disk is what is wanted here.
2. DO NOT change `network_mode: host` to a bridge network with `ports:`. It
   breaks the firewall restriction silently (see section 2) and degrades
   network-interface statistics, which is why the vendor requires host mode.
3. DO NOT add a healthcheck. The vendor documents `['CMD','/agent','health']`.
   Measured on 0.18.8: that command prints `ok` and exits 0 from a bare
   container with nothing running, with LISTEN pointing at a nonexistent
   socket, and with an explicit -l flag at a dead address. It would put a green
   light over a dead agent. The image is distroless, so no shell probe exists
   either.
4. DO NOT set HUB_URL or TOKEN. Those select the agent-dials-hub WebSocket
   path. Every one of these nodes reports source country US, and the zone's
   firewall blocks every non-local country ahead of Cloudflare Access, so an
   outbound agent would be blocked and the symptom would read as an auth
   failure. The hub dials in instead. This is phoenixlab ADR 0005.
5. DO NOT create DNS records, Access applications, or tunnel ingress rules for
   these agents. They are not reachable from the internet and must not be.
6. DO NOT use `henrygd/beszel-agent:latest`. Pin the tag.
7. DO NOT stop or remove netdata, its volumes, its health.d config, or the
   vps0N-metrics hostnames. A public status page at the zone apex polls
   netdata's REST API on all three via an Access service token; removing them
   takes that page dark and it fails closed, rendering the nodes as DOWN.

## 5. ROLLBACK

Remove the service block and redeploy. Remove the firewall rule per section
2.6. The `beszel-agent-data` volumes hold no data worth keeping and may be
removed by hand afterwards. Nothing else is touched.

## 6. NOT YOUR JOB

Adding each node as a system in the Beszel hub is done from the phoenixlab
side, using host = the node's address and port 45876. Report back when the
three agents are listening; do not attempt to reach the hub.
