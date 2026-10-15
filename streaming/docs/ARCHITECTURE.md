For a **local-first version**, I’d keep it production-shaped but operationally simple.

## Recommended local architecture

```text
          B3 historical files
                 │
                 ▼
        ┌──────────────────┐
        │ Replay Producer  │
        │ Python / Rust    │
        └────────┬─────────┘
                 │
                 ▼
        ┌──────────────────┐
        │ Kafka            │
        │ Redpanda or      │
        │ Apache Kafka     │
        └────────┬─────────┘
                 │
                 ▼
        ┌──────────────────┐
        │ Apache Flink     │
        │                  │
        │ • VWAP           │
        │ • volume windows │
        │ • positions      │
        │ • anomalies      │
        └───────┬──────────┘
                │
        ┌───────┴─────────┐
        ▼                 ▼
┌──────────────┐   ┌──────────────┐
│ MinIO        │   │ PostgreSQL   │
│ S3-compatible│   │ serving DB   │
└──────────────┘   └──────┬───────┘
                          │
                          ▼
                    ┌──────────┐
                    │ Grafana  │
                    └──────────┘
```

Run all infrastructure with **Docker Compose**.

## Stack I would use

| Layer | Local choice | Later on AWS |
|---|---|---|
| Event broker | **Redpanda** or Kafka | MSK |
| Stream processing | **Apache Flink** | Managed Service for Apache Flink / EKS |
| Object storage | **MinIO** | S3 |
| Serving DB | **PostgreSQL** | RDS/Aurora |
| Dashboard | **Grafana** | Managed Grafana |
| Metrics | **Prometheus** | CloudWatch / Managed Prometheus |
| Schema registry | Redpanda Schema Registry / Confluent-compatible | Glue Schema Registry or equivalent |
| Infrastructure | Docker Compose | Terraform |

### Kafka vs Redpanda locally

I would start with **Redpanda**.

It implements the Kafka protocol but is substantially easier to run locally because you don't need to manage ZooKeeper/KRaft complexity just to get started.

Your application code still uses normal Kafka clients:

```python
bootstrap_servers = "redpanda:9092"
```

Later:

```python
bootstrap_servers = "your-msk-cluster.amazonaws.com:9092"
```

The application architecture doesn't need to change much.

If your main objective is explicitly to learn Kafka administration, then use Apache Kafka from day one.

---

# Topic design

Don't create twenty topics initially.

Start with:

```text
market.raw
market.trades
market.quotes
market.metrics
market.alerts
```

Flow:

```text
B3 data
   │
   ▼
market.raw
   │
   ▼
Flink normalization
   │
   ├── market.trades
   └── market.quotes
          │
          ▼
      Flink jobs
          │
          ├── market.metrics
          └── market.alerts
```

This gives you separation between:

- ingestion
- normalization
- business processing

without overengineering.

---

# First Flink job

Your first Flink job should be simple enough to debug but still demonstrate real streaming concepts.

Build:

## `market-metrics`

Input:

```text
market.trades
```

Key by:

```text
symbol
```

Then calculate 1-minute windows:

```text
PETR4

last_price
trade_count
total_volume
high
low
VWAP
```

Output:

```json
{
  "symbol": "PETR4",
  "window_start": "2026-10-14T14:01:00Z",
  "window_end": "2026-10-14T14:02:00Z",
  "last_price": 32.51,
  "high": 32.55,
  "low": 32.46,
  "volume": 182300,
  "trade_count": 421,
  "vwap": 32.493
}
```

Send that to:

```text
market.metrics
```

and persist it into PostgreSQL.

That alone gives you:

- Kafka producers/consumers
- partitioning
- event-time processing
- Flink windows
- state
- checkpoints
- database sinks

---

# Storage design

Use MinIO as your local S3.

Persist raw events:

```text
s3://market-data/raw/
  date=2026-10-14/
    symbol=PETR4/
```

And optionally processed data:

```text
s3://market-data/processed/
  metrics/
  trades/
```

Initially I would **not introduce Iceberg**.

Start with:

```text
Parquet + MinIO
```

Once the pipeline is working, introduce Iceberg.

Otherwise you can easily spend more time debugging catalog configuration than learning Kafka/Flink.

---

# Replay service

Make the replay service configurable.

For example:

```bash
python replay.py \
  --file data/b3-2026-10-13.csv \
  --speed 10 \
  --symbols PETR4,VALE3,ITUB4
```

Support:

```text
--speed 1
--speed 10
--speed 100
--speed max
```

This becomes very useful later.

At:

```text
1x
```

you test realistic behavior.

At:

```text
100x
```

you load test the system.

At:

```text
max
```

you test throughput and backpressure.

---

# Partitioning strategy

This is worth getting right early.

For market events:

```text
Kafka key = symbol
```

For example:

```text
PETR4 → partition 3
PETR4 → partition 3
PETR4 → partition 3

VALE3 → partition 7
VALE3 → partition 7
```

That preserves ordering per instrument.

Then Flink:

```java
.keyBy(event -> event.symbol)
```

You now have deterministic per-symbol processing.

That is exactly the type of design decision you'll likely discuss in a DataOps/streaming interview.

---

# Local observability

Add:

```text
Prometheus
Grafana
```

Expose metrics from:

### Kafka / Redpanda

```text
message throughput
consumer lag
partition count
disk usage
```

### Flink

```text
records in/sec
records out/sec
checkpoint duration
checkpoint failures
backpressure
job restarts
```

### Your producer

```text
events produced/sec
publish latency
errors
```

Grafana dashboard:

```text
┌───────────────────────────────────┐
│ Market Streaming Platform        │
├───────────────────────────────────┤
│ Events/sec       12,843           │
│ Kafka lag         1,244           │
│ Flink latency      82ms           │
│ Checkpoint         430ms          │
│ Failed events      0              │
└───────────────────────────────────┘
```

This is especially relevant for the **DataOps** angle.

---

# Docker Compose layout

I would structure it like this:

```text
real-time-capital-markets/

├── compose.yaml
│
├── data/
│   └── raw/
│
├── producer/
│   ├── Dockerfile
│   ├── replay.py
│   └── pyproject.toml
│
├── flink/
│   ├── market-metrics/
│   ├── position-engine/
│   └── common/
│
├── schemas/
│   ├── trade.avsc
│   └── quote.avsc
│
├── storage/
│   └── init/
│
├── postgres/
│   └── init.sql
│
├── observability/
│   ├── prometheus.yml
│   └── grafana/
│
└── docs/
    └── architecture.md
```

Your Compose file initially runs:

```text
redpanda
redpanda-console
flink-jobmanager
flink-taskmanager
minio
postgres
prometheus
grafana
```

That's enough.

---

# Add a Kafka UI

I strongly recommend adding one.

If using Redpanda:

```text
Redpanda Console
```

Then locally:

```text
http://localhost:8080
```

You can visually inspect:

- topics
- partitions
- messages
- schemas
- consumer groups
- lag

This saves a lot of debugging time.

---

# Local architecture I'd avoid initially

Don't start with:

```text
Kubernetes
+
Kafka
+
Flink Operator
+
Iceberg
+
Trino
+
Spark
+
Airflow
+
dbt
+
OpenTelemetry
+
Keycloak
```

That's a very common portfolio-project trap.

You'll spend weeks operating tooling rather than understanding the actual data system.

The important sequence is:

```text
events
 ↓
Kafka
 ↓
Flink
 ↓
state
 ↓
storage
 ↓
observability
```

Get that solid first.

---

# Build it in 4 stages

### Stage 1 — Streaming

```text
B3 file
 ↓
Replay producer
 ↓
Kafka
 ↓
console consumer
```

Goal: understand event ingestion and partitioning.

### Stage 2 — Flink

```text
Kafka
 ↓
Flink
 ↓
VWAP / volume / prices
 ↓
Kafka
```

Goal: understand stateful stream processing.

### Stage 3 — Persistence

```text
       ┌→ MinIO
Flink ─┤
       └→ PostgreSQL
```

Goal: historical + serving architecture.

### Stage 4 — Operations

Add:

```text
Prometheus
Grafana
checkpointing
failure injection
replay
consumer lag monitoring
```

Now it becomes a **DataOps project**, rather than merely a data engineering demo.

## Final local setup

If I were building this specifically to prepare for the Base interview, my local stack would be:

```text
                    ┌─────────────────┐
                    │ Real B3 dataset │
                    └────────┬────────┘
                             │
                       Replay Producer
                             │
                             ▼
                       ┌──────────┐
                       │ Redpanda │
                       │  Kafka   │
                       └────┬─────┘
                            │
                            ▼
                   ┌────────────────┐
                   │ Apache Flink   │
                   │                │
                   │ market-metrics │
                   │ positions      │
                   │ risk           │
                   └───────┬────────┘
                           │
               ┌───────────┼────────────┐
               ▼           ▼            ▼
             MinIO      PostgreSQL    Kafka
              S3         current      alerts
            history       state
               │           │
               └─────┬─────┘
                     │
              Prometheus/Grafana
```

Then, once this works reliably, **replace components one at a time with AWS equivalents using Terraform**. That gives you a clean migration story from local development to production-style cloud infrastructure.

Would you like the first local milestone to be a minimal Redpanda–Flink pipeline, or a fuller Docker Compose stack with MinIO, PostgreSQL, and Grafana from the start?