---
name: query-logs
description: Query the OpenObserve log stack from the CLI — read container or system logs, answer "what did container X log", debug an app error after the fact, or check that log ingestion works. Covers the SSH + curl access pattern, the search payload shape, and the field-name gotchas.
---

# Query logs (OpenObserve)

Parent: ../../CLAUDE.md. Design context: `stacks/CLAUDE.md` (Logs section).
All facts below verified 2026-08-23/24.

Logs, not metrics. Metrics are Netdata (`http://127.0.0.1:19999` on each
node, per-container cgroup charts labelled by container ID).

## Access pattern

OpenObserve listens only on `127.0.0.1:5080` on vps02, so query from the
node. Credentials live in the node's `.env` and stay there — never print
them (rail 11).

```sh
ssh vps02-root
# on the node:
set -a; . /opt/stacks/vps02/.env; set +a
curl -s -u "$OPENOBSERVE_INGEST_USER:$OPENOBSERVE_INGEST_PASSWORD" \
  -H "Content-Type: application/json" \
  http://127.0.0.1:5080/api/default/_search \
  -d '<payload>'
```

The ingest user is an **admin** — OSS OpenObserve has no least-privilege
role — so treat the credentials accordingly.

UI equivalent: `https://siem.maybeit.work` (Access-gated, owner-only,
PH-only).

## Payload shape

```json
{"query":{"sql":"...","start_time":<epoch_us>,"end_time":<epoch_us>,"size":N}}
```

Times are epoch **microseconds**. On the node, "last hour":

```sh
START=$(( $(date +%s) - 3600 ))000000
END=$(date +%s)000000
```

## The stream and its fields

- Stream is `journal`: the systemd journal **and** all container stdout
  from all three nodes (Docker journald log driver), one stream.
- Field names are **lowercase** in SQL: `container_name`, `node`
  (values `vps00|vps01|vps02`), `message`. Uppercase `CONTAINER_NAME`
  fails with `unknown field`; the error's `suggestions` list is
  trustworthy — use it.

Example that worked:

```sql
SELECT container_name, COUNT(*) FROM journal
WHERE node = 'vps01' AND container_name IN ('ezbookkeeping')
GROUP BY container_name
```

## Checking ingestion

`doc_num` on `/api/default/streams` reads 0 while rows are already
queryable (WAL not yet flushed). Use `_search` to decide whether
ingestion works: zero rows there means nothing arrived; zero `doc_num`
means nothing flushed yet.
