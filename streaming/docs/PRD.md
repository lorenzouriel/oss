Yes. You can avoid purely synthetic events.

For a portfolio project, I’d use **real B3 market data as the source**, then turn it into a Kafka stream yourself.

B3 officially publishes historical equity quote data going back to 1986, including ticker, OHLC prices, number of trades, and traded value. [B3](https://www.b3.com.br/en_us/market-data-and-indices/data-services/market-data/historical-data/equities/historical-quote-data/?utm_source=chatgpt.com) It also publishes daily trading-session files such as the `BVBG.086.01 PriceReport`, instrument reference files, index reports, and other market datasets. [B3](https://www.b3.com.br/en_us/market-data-and-indices/data-services/market-data/historical-data/newsletters/search-by-trading-session/?utm_source=chatgpt.com)

The architecture becomes:

```text
Real B3 files / API
        │
        ▼
Ingestion service
        │
        ▼
Kafka
        │
        ▼
Apache Flink
        │
        ├── market metrics
        ├── VWAP
        ├── volatility
        ├── volume windows
        ├── anomaly detection
        └── market state
        │
        ├──────────────┐
        ▼              ▼
       S3          PostgreSQL
   historical      serving layer
```

The strongest version is to take **historical market events and replay them as though they were occurring live**.

For example, suppose you have records from a trading day:

```text
10:00:00.120 PETR4 32.10
10:00:00.241 PETR4 32.11
10:00:00.392 VALE3 61.43
10:00:00.510 PETR4 32.12
...
```

Your replay producer preserves the event-time differences:

```text
B3 historical data
        │
        ▼
Replay Engine
        │
        │ 1x / 10x / 100x speed
        ▼
Kafka
```

Then Flink doesn't know that the events happened in the past. Operationally, it behaves like a live streaming system.

That gives you **real market distributions, real tickers, real trading patterns and real volume spikes**, while still letting you control load and failure scenarios.

One limitation is important: B3's freely available historical quote dataset is primarily aggregated quotation data rather than a complete public real-time exchange feed. B3's richer information products and APIs have separate commercial/licensing models. B3 has a developer/API ecosystem, but those APIs are licensed products rather than a blanket free real-time equities WebSocket feed. [B3](https://www.b3.com.br/pt_br/market-data-e-indices/servicos-de-dados/b3-for-developers/?utm_source=chatgpt.com)

So I would structure your project in two source modes:

```text
                    Market Source
                         │
                ┌────────┴─────────┐
                │                  │
             REPLAY              LIVE
                │                  │
         B3 historical         external API
              files            / provider
                │                  │
                └────────┬─────────┘
                         ▼
                 Normalized Events
                         │
                         ▼
                       Kafka
```

That is actually better engineering than hard-coding one source because you can define a canonical event schema such as:

```json
{
  "event_id": "b3-PETR4-1728912345123",
  "event_time": "2026-10-13T13:31:24.512Z",
  "exchange": "B3",
  "symbol": "PETR4",
  "event_type": "TRADE",
  "price": 32.51,
  "quantity": 500,
  "currency": "BRL"
}
```

and every source gets normalized into it.

### What I'd personally build

I'd call the project:

**Brazilian Market Streaming Platform**

and use:

```text
B3 Historical Market Data
        ↓
Python/Rust replay service
        ↓
Kafka
        ↓
Flink
        ↓
├── Real-time VWAP
├── Rolling volume
├── Price movement
├── Volatility
├── Trading halt/anomaly detection
├── Top movers
└── Market aggregates
        ↓
S3 / Iceberg
        +
PostgreSQL
        +
Grafana
```

Then add Terraform to deploy:

```text
AWS
├── VPC
├── MSK
├── Managed Flink
├── S3
├── IAM
├── CloudWatch
└── compute for ingestion
```

That would give you **real source data + the exact infrastructure concepts likely relevant to the Base role**, without needing privileged access to an actual exchange feed.

One caution: B3 explicitly restricts automated collection from at least some of its web pages, including its trading-session search page, so I would use datasets/files/APIs whose access terms permit your intended usage rather than scraping the website. [B3](https://b3.com.br/pt_br/market-data-e-indices/servicos-de-dados/market-data/historico/boletins-diarios/pesquisa-por-pregao/pesquisa-por-pregao/?utm_source=chatgpt.com)

If your goal is to make this as close as possible to what a Base DataOps engineer might handle, **historical B3 data replayed through Kafka/Flink is probably the best starting point.**

Would you like to use B3 historical files for replay, or connect a licensed live market-data provider?