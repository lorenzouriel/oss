# Real-time capital markets streaming

Historical B3 market data replayed as a live Kafka stream, processed by Flink. See [ARCHITECTURE.md](ARCHITECTURE.md) and [PRD.md](PRD.md).

## Run locally

```bash
cp .env.example .env   # optional, every value has a default
docker compose up -d
```

One-shot init containers create the Kafka topics (`market.raw`, `market.trades`, `market.quotes`, `market.metrics`, `market.alerts`, 6 partitions each) and the S3 buckets (`market-data`, `flink`). Postgres runs [postgres/init.sql](postgres/init.sql) on first start.

| Service | URL | Credentials |
|---|---|---|
| Redpanda Console | http://localhost:8080 | — |
| Kafka API (host clients) | `localhost:19092` | — |
| Schema Registry | http://localhost:18081 | — |
| Flink UI | http://localhost:8081 | — |
| S3 API (SeaweedFS) | http://localhost:8333 | `admin` / `admin12345` |
| S3 file browser | http://localhost:8888/buckets/ | — |
| PostgreSQL | `localhost:5432` | `market` / `market` |
| Prometheus | http://localhost:9090 | — |
| Grafana | http://localhost:3000 | `admin` / `admin` |

Containers inside the network use `redpanda:9092`, `seaweedfs:8333` and `postgres:5432`.

**Object storage:** the architecture calls for MinIO, but MinIO no longer publishes public Docker images, so the local S3 is SeaweedFS. Clients only see an S3 endpoint (path-style access), so it maps to AWS S3 the same way.

**Flink:** RocksDB state backend, checkpoints every 30s to `s3://flink/checkpoints`, Prometheus metrics on port 9249. Put job jars in `flink/jobs/` and submit them:

```bash
docker compose exec flink-jobmanager flink run -d /opt/flink/jobs/market-metrics.jar
```

Reset everything (including data volumes):

```bash
docker compose down -v
```
