# Epics

The remaining work for the Brazilian Market Streaming Platform, split into epics. Architecture: [ARCHITECTURE.md](ARCHITECTURE.md). Source strategy: [PRD.md](PRD.md).

## Status

| # | Epic | Stage | Depends on | Status |
|---|---|---|---|---|
| 0 | Local platform | — | — | ✅ Done |
| 1 | Market data source & event contract | 1 | 0 | ⬜ |
| 2 | Replay producer | 1 | 1 | ⬜ |
| 3 | Flink foundations & normalization job | 2 | 1, 2 | ⬜ |
| 4 | `market-metrics` job | 2 | 3 | ⬜ |
| 5 | Persistence: Postgres + S3 | 3 | 4 | ⬜ |
| 6 | Alerts & market analytics | 2–3 | 4 | ⬜ |
| 7 | Observability | 4 | 2, 4 | ⬜ |
| 8 | Reliability & failure testing | 4 | 5, 7 | ⬜ |
| 9 | CI & developer experience | — | 2, 3 | ⬜ |
| 10 | AWS migration (Terraform) | later | 8 | ⬜ |
| 11 | Iceberg tables | later | 5 | ⬜ |
| 12 | Live source mode | later | 2 | ⬜ |

```text
0 ─► 1 ─► 2 ─► 3 ─► 4 ─┬─► 5 ─┬─► 8 ─► 10
                       │      └─► 11
                       ├─► 6
                       └─► 7 ──► 8
     2 ─► 12          2,3 ─► 9 (start early, runs alongside)
```

Critical path to a working Stage 1–4 demo: **1 → 2 → 3 → 4 → 5 → 7 → 8**.

---

## Epic 0 — Local platform ✅

Docker Compose stack: Redpanda + Console, Flink 1.20 (RocksDB, 30s checkpoints to S3), SeaweedFS as the S3 store, Postgres 17, Prometheus, Grafana. Init containers create the 5 topics, the 2 buckets and the serving schema. See [README.md](../README.md).

---

## Epic 1 — Market data source & event contract

**Goal:** a legally usable B3 dataset at the granularity the Flink jobs need, and a versioned event schema every source normalizes into.

**Why first:** free B3 historical data (COTAHIST) is **one OHLC row per ticker per day**. The architecture's core job, 1-minute VWAP windows, needs intraday trades. This decides what Epics 2–4 can actually compute.

**Stories**
- **Spike: intraday source.** Check free B3 intraday/tick trade files (the daily trade files published on arquivos.b3.com.br, and how many days back they go). Confirm the terms permit download, since PRD warns B3 restricts automated collection on some pages. Record format, size per day, fields and history depth.
- **Decision record:** pick one:
  - (a) real intraday trades (preferred), or
  - (b) COTAHIST daily bars with intraday ticks synthesized from each day's OHLC/volume, clearly marked as synthetic, or
  - (c) daily bars only, with windows changed to daily/weekly.

  Write it up as an ADR in `docs/`.
- **Quotes:** confirm whether any free source has bid/ask. If not, drop `market.quotes` and `quote.avsc` from v1, or note them as reserved.
- **Event schema:** `schemas/trade.avsc` (and `quote.avsc` if kept), based on the PRD's canonical event: `event_id`, `event_time`, `exchange`, `symbol`, `event_type`, `price`, `quantity`, `currency`, plus `source` and `ingested_at`. Decide money types (decimal logical type vs double).
- **Schema Registry:** register the schemas with BACKWARD compatibility; add the registration to the `redpanda-init` container.
- **Sample data:** a download script into `data/raw/`, plus a small checked-in fixture (one symbol, a few minutes) for tests.

**Done when:** the ADR is merged, the schemas are registered automatically on `docker compose up`, and one real trading day is downloadable with one command.

---

## Epic 2 — Replay producer (Stage 1)

**Goal:** replay a historical day into `market.raw` as if it were live.

**Stories**
- `producer/` Python project (`pyproject.toml`, `replay.py`), `Dockerfile`, and a compose service (e.g. a `producer` profile so it doesn't start by default).
- CLI: `--file`, `--symbols`, `--speed 1|10|100|max`, `--start-at` / `--limit`. Preserve the gaps between event times, scaled by speed; `max` sends with no sleeps.
- Kafka key = `symbol`; Avro serialization through the Schema Registry; idempotent producer, `acks=all`.
- Deterministic `event_id`, so replaying the same file twice produces the same IDs (Epic 3 dedups on it).
- Prometheus `/metrics` on `:8000`: events produced/sec, publish latency, errors. Turn on the `producer` scrape job already in [prometheus.yml](../observability/prometheus.yml).
- Graceful shutdown: flush on SIGTERM; log a summary of events sent and how long it took.
- Unit tests: parsing, speed scaling, key assignment.

**Done when:** `docker compose --profile producer up` replays a day; Redpanda Console shows the messages spread across the 6 partitions, with every event for a symbol in the same partition; `rpk topic consume market.raw` decodes them.

---

## Epic 3 — Flink foundations & normalization job (Stage 2)

**Goal:** a repeatable way to build and deploy Flink jobs, and the first job, which turns `market.raw` into clean `market.trades`.

**Stories**
- **Language decision:** Java (matches the architecture snippets and has the most mature APIs) vs PyFlink. Record it in an ADR.
- `flink/common/`: shared event POJOs/serdes, Kafka source/sink builders, and config loading.
- Build: Maven/Gradle multi-module, fat jars written to `flink/jobs/`, and a `make deploy-<job>` target that submits a job through the jobmanager.
- **`normalization` job:** validate the schema and field ranges (price > 0, quantity > 0, known symbol), dedup on `event_id` with keyed state + TTL, and route rejects to a dead-letter topic (adds `market.dlq`; update the init script).
- Event-time watermarks with bounded out-of-orderness (the bound is configurable).
- Exactly-once Kafka sink (transactional), so it works with the checkpoints already configured.
- Tests: Flink MiniCluster test fed by the Epic 1 fixture.

**Done when:** replaying a day produces deduplicated records in `market.trades`; malformed records land in `market.dlq`; killing the taskmanager mid-replay doesn't create duplicates in `market.trades`.

---

## Epic 4 — `market-metrics` job (Stage 2)

**Goal:** per-symbol 1-minute bars with VWAP, exactly as in the architecture doc.

**Stories**
- Keyed by `symbol`, tumbling 1-minute event-time windows: `last_price`, `high`, `low`, `volume`, `trade_count`, `vwap`, `window_start`, `window_end`.
- Late data: allowed lateness plus a side output for events that arrive too late; count them as a metric.
- Output to `market.metrics` (schema `metric.avsc`, registered).
- Custom Flink metrics: late events, records per window.
- Golden test: compute a fixture's bars independently (e.g. a pandas script) and check that the job matches them exactly.

**Done when:** a replayed day yields one bar per symbol per minute with trades, and the bars equal the golden output.

---

## Epic 5 — Persistence: Postgres + S3 (Stage 3)

**Goal:** a serving layer (current state) plus history (raw and processed).

**Stories**
- **Postgres sink:** JDBC sink from `market.metrics` → `market_metrics`, upserting on `(symbol, window_start)`. The table in [init.sql](../postgres/init.sql) is already built for this, so restarts and replays stay idempotent.
- **Raw archive:** Parquet FileSink from `market.trades` → `s3://market-data/raw/date=YYYY-MM-DD/symbol=XXXX/`, with files committed on checkpoint.
- **Processed archive:** `market.metrics` → `s3://market-data/processed/metrics/`.
- Decide: one job with multiple sinks vs one job per sink. Document the trade-off: isolation vs operating more jobs.
- Verify by querying the Parquet output with DuckDB, and reconcile row counts against Kafka offsets.

**Done when:** after a replay, row counts in Postgres, the S3 metrics files and `market.metrics` all match. Running the same day again leaves the Postgres row count unchanged.

---

## Epic 6 — Alerts & market analytics

**Goal:** the analytics the PRD lists, beyond VWAP.

**Stories**
- **Anomaly alerts → `market.alerts` → `market_alerts`:** price jump above N σ within a window, volume spike vs the rolling average, and no trades for a symbol that should be trading (halt detection).
- Rolling volatility (e.g. 20-window standard deviation of returns per symbol).
- Top movers and market-wide aggregates: total volume, advancers vs decliners, per minute.
- **Positions engine:** needs a portfolio/orders input that doesn't exist yet. Either define a small synthetic portfolio topic, or drop it from v1. Decide explicitly.
- Alert IDs must be deterministic, so the `market_alerts` primary key dedups replays.

**Done when:** replaying a known volatile day (choose one during the Epic 1 spike) fires the expected alerts, and they show up in Postgres.

---

## Epic 7 — Observability (Stage 4)

**Goal:** the "Market Streaming Platform" Grafana dashboard from the architecture doc, provisioned as code.

**Stories**
- Grafana dashboard provisioning (`observability/grafana/provisioning/dashboards/`), with the dashboard JSON in the repo.
- **Platform dashboard:** events/sec (producer and Redpanda), consumer lag per group, Flink records in/out per second, end-to-end latency, checkpoint duration and failures, backpressure, job restarts, DLQ rate.
- **Market dashboard (Postgres):** VWAP and price per symbol, volume, latest alerts.
- **Consumer lag:** confirm which Redpanda metric exposes per-group lag in v24.3. If none fits, add a lag exporter.
- **End-to-end latency:** carry the producer's send time on each event, and measure it again at the sink as a Flink histogram.
- Prometheus alert rules: lag above a threshold, checkpoint failures, no events for N minutes, job restarting.

**Done when:** a fresh `docker compose up` shows both dashboards filled during a replay, with no manual Grafana steps.

---

## Epic 8 — Reliability & failure testing (Stage 4)

**Goal:** show the system recovers correctly, which is the core DataOps story.

**Stories**
- Failure scenarios, each scripted and repeatable:
  - kill the taskmanager mid-window
  - restart Redpanda
  - make S3 unavailable
  - inject poison messages
  - make Postgres unavailable during sink writes
- After each scenario, verify no data was lost or duplicated, using the Epic 5 count reconciliation.
- Savepoint workflow: stop with a savepoint → change the job → resume. Document it as a runbook.
- Backfill: reprocess a past day by resetting offsets or replaying the file; Postgres upserts make this safe.
- Load test at `--speed max`: find the throughput ceiling, watch backpressure, then tune parallelism and partitions. Write up the results.
- Runbooks in `docs/runbooks/`: consumer lag rising, checkpoint failing, replaying a day.

**Done when:** every scenario has a script, the expected result and an observed result, and all pass with exact counts.

---

## Epic 9 — CI & developer experience

**Goal:** anyone can clone, run and test the project. Start alongside Epics 2–3.

**Stories**
- `Makefile`: `up`, `down`, `reset`, `replay DAY=...`, `build-jobs`, `deploy-jobs`, `test`.
- GitHub Actions: producer tests, Flink job tests, `docker compose config` validation, and schema compatibility checks.
- Integration smoke test in CI: bring up the stack, replay the fixture, assert rows in Postgres.
- README: architecture diagram, a quickstart, and an "interview walkthrough" section (the design decisions and why).

**Done when:** a clean clone gets to a populated dashboard with `make up && make replay`, and CI is green.

---

## Later epics

### Epic 10 — AWS migration (Terraform)
Swap components one at a time: VPC, IAM, Redpanda → MSK, local S3 → S3, Postgres → RDS, Flink → Managed Service for Apache Flink, Prometheus/Grafana → Managed Prometheus/Grafana or CloudWatch, and the producer on ECS. Include remote state, environments (dev/prod), CI deploys, and a cost estimate plus teardown script. **Done when:** the same replay runs end to end on AWS and `terraform destroy` cleans it all up.

### Epic 11 — Iceberg tables
Replace the Parquet archives with Iceberg tables (Flink Iceberg sink + a REST catalog), adding time travel and schema evolution. The architecture doc defers this on purpose until the pipeline is solid.

### Epic 12 — Live source mode
A second producer behind the same event schema that reads from a licensed or delayed market-data API. This proves the PRD's REPLAY/LIVE source abstraction. It depends on finding a provider with acceptable terms.

---

## Open decisions

| Decision | Epic | Options |
|---|---|---|
| Intraday data source | 1 | Real B3 trade files / synthetic ticks from OHLC / daily-only windows |
| Keep `market.quotes`? | 1 | Only if a bid/ask source exists |
| Flink job language | 3 | Java / PyFlink |
| Dead-letter topic | 3 | Add `market.dlq` (recommended) / log only |
| Positions engine scope | 6 | Synthetic portfolio topic / drop from v1 |
| Object store | — | SeaweedFS stays (MinIO images unavailable) / RustFS, matching the batch project |
