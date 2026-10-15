That stack can work well, but I would give **DuckLake and Iceberg different roles**. They overlap: both are lakehouse formats. Polaris is specifically an Iceberg REST catalog, while DuckLake stores its own catalog metadata in a transactional SQL database and its table data in Parquet. [Apache Polaris](https://polaris.apache.org/?utm_source=chatgpt.com)

So I would **not** make both DuckLake and Iceberg co-equal storage formats for the same Bronze/Silver/Gold tables. That creates two catalogs, two transaction models, and unnecessary synchronization.

## Recommended open-source architecture

```text
                         DATA SOURCES
            CVM | BCB | Tesouro | Market APIs
                          │
                          ▼
                 ┌─────────────────┐
                 │     AIRFLOW     │
                 │                 │
                 │ orchestration   │
                 │ scheduling      │
                 │ retries         │
                 │ dependencies    │
                 └────────┬────────┘
                          │
                          ▼
                    Python / DuckDB
                     ingestion jobs
                          │
                          ▼
                S3-compatible storage
                          │
        ┌─────────────────┼──────────────────┐
        │                 │                  │
        ▼                 ▼                  ▼
     BRONZE             SILVER              GOLD
     Iceberg            Iceberg             Iceberg
        │                 │                  │
        └─────────────────┴──────────────────┘
                          │
                          ▼
                 ┌─────────────────┐
                 │ APACHE POLARIS  │
                 │                 │
                 │ Iceberg REST    │
                 │ catalog         │
                 └────────┬────────┘
                          │
               ┌──────────┼───────────┐
               │          │           │
               ▼          ▼           ▼
            DuckDB       dbt     OpenMetadata
               │          │           │
               │      models/tests    │
               │          │       metadata/
               │          │       lineage/
               │          │       glossary
               │          │           │
               └──────────┼───────────┘
                          ▼
                       AGENT
                    LangGraph
                          │
                ┌─────────┼─────────┐
                ▼         ▼         ▼
             SQL Tool  Metadata   Lineage
                │         Tool       Tool
                ▼          │          │
             DuckDB        └────┬─────┘
                │               │
                └───────┬───────┘
                        ▼
                     ANSWER
```

That's the architecture I would commit to.

---

# Role of each technology

## 1. Apache Iceberg — canonical lakehouse format

Make Iceberg the actual persistent format for the Medallion architecture.

```text
Object storage

warehouse/
├── bronze/
├── silver/
└── gold/
```

Conceptually:

```text
bronze.cvm_dfp
bronze.cvm_itr
bronze.bcb_sgs
bronze.market_prices

silver.company
silver.security
silver.security_price
silver.financial_metric
silver.macro_observation

gold.company_daily
gold.company_financials
gold.company_ratios
gold.market_daily
gold.macro_daily
```

Iceberg gives you:

- snapshots
- ACID commits
- schema evolution
- partition evolution
- time travel
- incremental reads
- multiple-engine interoperability

And because it isn't tied to DuckDB, you're not locking the project to one compute engine.

---

# 2. Apache Polaris — technical catalog

Polaris sits **above the Iceberg tables**.

```text
                 Polaris

                   │
        Iceberg REST Catalog API
                   │
        ┌──────────┼──────────┐
        ▼          ▼          ▼
     DuckDB      Spark      future engine
```

Polaris implements the Iceberg REST API, so compatible clients can access the same catalog without having to understand a proprietary catalog implementation. [Apache Iceberg](https://iceberg.apache.org/docs/latest/rest-catalog/?utm_source=chatgpt.com)

This distinction is important:

### Polaris

Answers:

> Where is `gold.company_daily`?

> Which Iceberg snapshot is current?

> Can this engine write this table?

### OpenMetadata

Answers:

> What does `company_daily` mean?

> Who owns it?

> What's upstream?

> What does `roe` mean?

> How fresh is the data?

Those are **different catalog responsibilities**.

---

# 3. DuckDB — execution engine

I think DuckDB fits your project extremely well.

Use it for:

```text
API JSON/CSV
     ↓
DuckDB
     ↓
clean / reshape / join
     ↓
Iceberg
```

and later:

```text
Agent
  ↓
SQL
  ↓
DuckDB
  ↓
Polaris
  ↓
Iceberg
```

DuckDB's Iceberg extension now supports attaching Iceberg REST catalogs and reading/writing catalog-backed Iceberg tables; the current docs explicitly include Apache Polaris among supported catalog implementations. [DuckDB](https://duckdb.org/docs/current/core_extensions/iceberg/catalogs?utm_source=chatgpt.com)

So you don't necessarily need Trino initially.

That keeps your OSS stack much lighter.

---

# 4. DuckLake — local development / experimentation

This is where I'd be deliberate.

DuckLake 1.0 is now production-ready and is itself a complete lakehouse format: metadata lives in a SQL catalog and data lives in Parquet. [DuckLake](https://ducklake.select/2026/04/13/ducklake-10/?utm_source=chatgpt.com)

Therefore:

```text
DuckLake ≈ alternative to Iceberg + Polaris
```

not:

```text
DuckLake → Iceberg → Polaris
```

I would use DuckLake for **developer mode**.

For example:

```text
Production / shared mode

S3-compatible storage
      +
Iceberg
      +
Polaris
```

versus:

```text
Local mode

DuckDB
  +
DuckLake
  +
local Parquet
```

This gives contributors an extremely low-friction setup.

### Developer

```bash
make dev-lite
```

could run:

```text
DuckDB
DuckLake
Airflow
dbt
```

without requiring object storage + Polaris.

### Full stack

```bash
make dev-full
```

runs:

```text
Object storage
Polaris
Iceberg
DuckDB
Airflow
dbt
OpenMetadata
Agent
```

That's an excellent OSS story.

---

# Why DuckLake is valuable here

A new contributor shouldn't necessarily need:

```text
Polaris
object storage
Postgres
OpenMetadata
...
```

just to work on:

```text
silver.financial_metric
```

DuckLake can provide a lightweight local lakehouse.

Its docs explicitly position DuckDB-backed DuckLake for local single-client environments and PostgreSQL-backed DuckLake for multi-user scenarios. [DuckLake](https://ducklake.select/docs/stable/duckdb/usage/choosing_a_catalog_database?utm_source=chatgpt.com)

So your architecture supports:

```text
                    SAME DATA MODEL

                        dbt
                         │
             ┌───────────┴───────────┐
             ▼                       ▼

       DEV / CI                  FULL STACK

        DuckLake             Iceberg + Polaris
            │                       │
          DuckDB                  DuckDB
```

That's how I would justify having **both DuckLake and Iceberg**.

---

# 5. Airflow — orchestration only

Airflow should not contain transformation logic.

Bad:

```python
@task
def calculate_roe():
    # 500 lines of pandas
```

Better:

```text
Airflow DAG

extract_cvm
      ↓
load_bronze
      ↓
dbt_build_silver
      ↓
dbt_test_silver
      ↓
dbt_build_gold
      ↓
dbt_test_gold
      ↓
publish_metadata
```

Airflow controls:

```text
WHEN
WHAT ORDER
RETRY POLICY
FAILURE HANDLING
BACKFILL
SCHEDULING
```

It should not define what ROE means.

---

# 6. dbt — transformation layer

dbt should own:

```text
Bronze → Silver
Silver → Gold
```

Repository:

```text
dbt/
│
├── models/
│   ├── bronze/
│   │
│   └── staging/
│   │
│   ├── silver/
│   │   ├── company.sql
│   │   ├── security.sql
│   │   ├── financial_metric.sql
│   │   └── security_price.sql
│   │
│   └── gold/
│       ├── company_daily.sql
│       ├── company_financials.sql
│       ├── company_ratios.sql
│       └── macro_daily.sql
│
├── tests/
├── macros/
└── seeds/
```

A useful mental model:

```text
Airflow = orchestration

dbt = transformation DAG

DuckDB = SQL execution

Iceberg = tables

Polaris = Iceberg catalog
```

---

# 7. dbt tests — data contracts and quality

This is very important for the project.

Tests should exist at each layer.

### Bronze

Mostly ingestion integrity:

```text
not_null(source)
not_null(ingested_at)

unique(source_file, source_row_id)
```

### Silver

Canonical-domain quality:

```text
company_id NOT NULL

ticker → security_id relationship

financial_metric.company_id
    REFERENCES company.company_id

close >= 0

period_end >= period_start
```

### Gold

Business invariants:

```text
ROE within plausible limits

market_cap >= 0

company_daily:
    unique(ticker, date)

no future financial statement
used before publication date
```

The last one is particularly important for finance.

---

# 8. OpenMetadata — semantic layer

OpenMetadata should consume metadata from:

```text
Polaris / Iceberg
dbt
Airflow
```

Then it becomes:

```text
                          OpenMetadata

          ┌────────────────────┼────────────────────┐
          │                    │                    │
       tables              dbt models           pipelines
          │                    │                    │
          ▼                    ▼                    ▼

     schemas             transformations          Airflow
     columns               + tests               lineage

                         +
                    business glossary
```

OpenMetadata supports lineage ingestion and dbt-derived lineage information, so you can expose the path from raw sources through transformations to analytical tables. [OpenMetadata Documentation](https://docs.open-metadata.org/v1.12.x/connectors/ingestion/lineage?utm_source=chatgpt.com)

For example:

```text
CVM DFP
   │
   ▼
bronze.cvm_dfp
   │
   ▼
silver.financial_metric
   │
   ▼
gold.company_financials
   │
   ▼
gold.company_ratios
```

The agent can later use this context.

---

# 9. Agent framework — LangGraph

I'd still use **LangGraph**, but keep the agent relatively small.

Architecture:

```text
                   USER

                    │
                    ▼
              LangGraph Agent
                    │
                    ▼
               classify intent
                    │
                    ▼
           discover metadata
                    │
            OpenMetadata tool
                    │
                    ▼
              identify tables
                    │
                    ▼
              generate SQL
                    │
                    ▼
               SQLGlot
              validation
                    │
                    ▼
                 DuckDB
                    │
                    ▼
          Polaris → Iceberg
                    │
                    ▼
                results
                    │
                    ▼
             grounded answer
```

Give it perhaps four tools:

```text
search_metadata()
get_lineage()
get_table_schema()
execute_sql()
```

That's enough for v1.

Don't give it arbitrary shell access, Python execution, or write access initially.

---

# The complete architecture

```text
                         EXTERNAL SOURCES

                 CVM   BCB   Tesouro   Market
                  │     │       │        │
                  └─────┴───────┴────────┘
                            │
                            ▼
                       AIRFLOW
                            │
                            ▼
                     Python / DuckDB
                            │
                            ▼
                    OBJECT STORAGE
                            │
                     Apache Iceberg
                            │
                            ▼
                      POLARIS
                 Iceberg REST Catalog
                            │
             ┌──────────────┼───────────────┐
             │              │               │
             ▼              ▼               ▼
           DuckDB           dbt        OpenMetadata
             │              │               │
             │         transformations       │
             │              │              lineage
             │              │              glossary
             │              │              quality
             │              │               │
             └──────────────┼───────────────┘
                            │
                            ▼
                         GOLD
                            │
                            ▼
                       LangGraph
                          Agent
                            │
                            ▼
                          User


LOCAL / CI ALTERNATIVE
────────────────────────────────────────

            dbt
             │
          DuckDB
             │
          DuckLake
             │
          Parquet
```

## My exact recommendation

Use these responsibilities:

| Technology | Responsibility |
|---|---|
| **DuckDB** | SQL/OLAP execution |
| **DuckLake** | lightweight local/CI lakehouse |
| **Iceberg** | canonical shared table format |
| **Polaris** | Iceberg REST catalog |
| **Airflow** | orchestration |
| **dbt** | Bronze → Silver → Gold transformations |
| **dbt tests** | data quality/contracts |
| **OpenMetadata** | metadata, glossary, lineage, observability |
| **LangGraph** | agent orchestration |
| **SQLGlot** | generated SQL validation |

The main architectural principle I'd enforce is:

> **DuckLake is the lightweight deployment profile; Iceberg + Polaris is the canonical full deployment profile.**

Don't write every table to both simultaneously.

That distinction prevents your stack from becoming redundant while still letting you showcase **DuckDB, DuckLake, Iceberg, Polaris, Airflow, dbt, data-quality engineering, metadata/lineage and agentic analytics** in one coherent open-source project. [DuckLake](https://ducklake.select/docs/stable/?utm_source=chatgpt.com)