Yes. I would reduce the design to **data sources → Bronze → Silver → Gold** and make everything else secondary.

# 1. Sources

For a Brazilian financial lakehouse, I would organize sources by **data domain**, not by provider.

| Domain | Primary source | Data | Interface |
|---|---|---|---|
| **Market** | B3 UP2DATA | prices, volume, instruments, indices, reference prices | CSV/JSON/XML/TXT |
| **Corporate** | CVM | companies, ITR, DFP, FCA, FRE, disclosures | ZIP/CSV/TXT |
| **Macro** | BCB SGS | SELIC, credit, monetary/economic series | JSON/CSV |
| **FX** | BCB PTAX | USD/BRL and other currencies | OData/JSON |
| **Expectations** | BCB | Focus-style market expectations | OData |
| **Rates** | Tesouro Transparente | government bond prices/yields | CSV |
| **Economy** | IBGE | GDP, industry, retail, employment etc. | API |
| **Documents** | CVM IPE / company IR | releases, notices, presentations | files/documents |

The authoritative market-data option is B3 UP2DATA. It distributes end-of-day/reference data, including equities, with security lists and trade/reference information; it is a contracted product and supports CSV, JSON, XML and TXT. [B3](https://www.b3.com.br/pt_br/market-data-e-indices/servicos-de-dados/up2data/?utm_source=chatgpt.com)

For a personal portfolio where B3 licensing is impractical, you can put a free/affordable market provider behind the same source boundary and swap it later.

---

# 2. CVM should be the backbone

CVM is probably your richest source.

I would ingest at least:

```text
CVM
│
├── Cadastro de Companhias
├── FCA
├── ITR
├── DFP
├── FRE
└── IPE
```

CVM currently publishes these datasets openly, including structured ZIP files for ITR, DFP, FCA and FRE. [Portal Dados Abertos CVM](https://dados.cvm.gov.br/dataset/?groups=companhias\&organization=cvm\&q=cadastro+de+ativos%2C\&utm_source=chatgpt.com)

### What each gives you

```text
Cadastro
    ↓
Who is the company?

FCA
    ↓
Registration / corporate information

ITR
    ↓
Quarterly financial statements

DFP
    ↓
Annual financial statements

FRE
    ↓
Company/business/risk/governance information

IPE
    ↓
Periodic/eventual disclosures and documents
```

DFP historical files are available by year, so this can give you substantial historical depth. [Portal Dados Abertos CVM](https://dados.cvm.gov.br/dados/CIA_ABERTA/DOC/DFP/DADOS/?utm_source=chatgpt.com)

---

# 3. BCB

I would separate BCB into different source datasets.

```text
BCB
│
├── SGS
│
│   ├── SELIC
│   ├── credit
│   ├── monetary indicators
│   └── economic indicators
│
├── PTAX
│   ├── USD/BRL
│   ├── EUR/BRL
│   └── other currencies
│
└── Expectations
    ├── inflation expectations
    ├── SELIC expectations
    ├── FX expectations
    └── GDP expectations
```

SGS provides machine-readable JSON/CSV time-series interfaces. [Banco Central do Brasil](https://dadosabertos.bcb.gov.br/dataset/1788-sgs?utm_source=chatgpt.com)

PTAX has an official OData/API interface and historical currency data; BCB says the underlying dataset is updated several times per day. [Banco Central do Brasil](https://dadosabertos.bcb.gov.br/dataset/taxas-de-cambio-todos-os-boletins-diarios?utm_source=chatgpt.com)

This is much better than obtaining macro/FX information through a generic finance API.

---

# 4. Tesouro

Another strong source:

```text
Tesouro Transparente
        ↓
Tesouro Direto

date
security
maturity
buy_price
sell_price
buy_yield
sell_yield
```

The official open dataset currently contains daily historical prices/rates going back to 2002 and is updated daily. [Tesouro Transparente](https://www.tesourotransparente.gov.br/ckan/dataset/taxas-dos-titulos-ofertados-pelo-tesouro-direto?utm_source=chatgpt.com)

That gives you a useful representation of the Brazilian interest-rate environment.

---

# 5. Then Medallion

The architecture becomes quite clean.

```text
                SOURCES

 B3       CVM       BCB      Tesouro      IBGE
  │        │         │          │           │
  └────────┴─────────┴──────────┴───────────┘
                     │
                     ▼

              ┌─────────────┐
              │   BRONZE    │
              │             │
              │ source data │
              │ immutable   │
              └──────┬──────┘
                     │
                     ▼
              ┌─────────────┐
              │   SILVER    │
              │             │
              │ canonical   │
              │ financial   │
              │ model       │
              └──────┬──────┘
                     │
                     ▼
              ┌─────────────┐
              │    GOLD     │
              │             │
              │ analytical  │
              │ products    │
              └─────────────┘
```

## Bronze — source-oriented

Bronze should resemble the original source.

For example:

```text
bronze/
│
├── b3/
│   ├── equities/
│   ├── indexes/
│   ├── instruments/
│   └── corporate_actions/
│
├── cvm/
│   ├── cadastro/
│   ├── dfp/
│   ├── itr/
│   ├── fca/
│   ├── fre/
│   └── ipe/
│
├── bcb/
│   ├── sgs/
│   ├── ptax/
│   └── expectations/
│
├── tesouro/
│   └── bonds/
│
└── ibge/
```

Keep:

```text
original columns
original values
original identifiers
```

and append metadata such as:

```text
_source
_dataset
_source_file
_source_url

_reference_date
_source_updated_at
_ingested_at

_content_hash
_ingestion_run_id
```

### Important rule

**Bronze never tries to create a common financial schema.**

CVM stays CVM-shaped.

BCB stays BCB-shaped.

B3 stays B3-shaped.

---

# 6. Bronze should retain revisions

This is particularly important for finance.

Suppose CVM publishes:

```text
ITR 2026-Q2
```

and later the company resubmits it.

Don't do:

```text
old record
   ↓
DELETE
   ↓
new record
```

Keep both.

```text
company     period       revision    received_at

PETR        2026-Q2         1        2026-08-08
PETR        2026-Q2         2        2026-08-14
```

The source may revise historical information.

Your lakehouse needs to know:

> What did we know **at a particular point in time?**

This becomes crucial if you later do backtesting.

---

# 7. Silver — source-independent

Silver is where you stop thinking:

```text
CVM table
BCB table
B3 file
```

and start thinking:

```text
Company
Security
Price
Financial Statement
Macro Series
Bond
Document
```

For example:

```text
silver/
│
├── company
├── security
├── security_price
├── corporate_action
│
├── financial_statement
├── financial_metric
│
├── macro_series
├── macro_observation
│
├── government_bond
├── government_bond_price
│
├── document
└── trading_calendar
```

This should be the **canonical financial model**.

---

# 8. `silver.company`

One common company representation:

```text
company_id
cnpj
cvm_code

legal_name
trade_name

sector
industry

registration_status

valid_from
valid_to
```

Source:

```text
CVM Cadastro
+
FCA
```

Then every other dataset joins through:

```text
company_id
```

rather than relying on names.

---

# 9. `silver.security`

Separate company from security.

Petrobras is a company.

PETR3 and PETR4 are securities.

```text
company
   │
   ├── PETR3
   └── PETR4
```

So:

```text
silver.security

security_id
company_id

ticker
isin

type

valid_from
valid_to
```

This distinction will save you many problems later.

---

# 10. `silver.security_price`

Market data becomes:

```text
security_id
trading_date

open
high
low
close

volume
trades

adjustment_factor
adjusted_close
```

Regardless of whether Bronze came from:

```text
B3 UP2DATA
```

or another market-data provider.

That's the advantage of Silver.

You can replace the source without changing downstream consumers.

---

# 11. Financial statements

I'd model these carefully.

CVM gives you different statements:

```text
BPA
BPP
DRE
DFC
DVA
DMPL
...
```

Rather than creating hundreds of company-specific columns, I'd initially use a metric/fact model:

```text
silver.financial_metric

company_id
period_start
period_end

statement
account_code
account_name

metric
value

currency
consolidated

published_at
revision
```

Then normalized `metric` can eventually become:

```text
revenue
gross_profit
ebit
net_income

cash
total_assets
total_debt
equity

operating_cash_flow
capex
```

while retaining:

```text
account_code
account_name
```

from CVM for traceability.

---

# 12. Macro becomes very simple

BCB:

```text
silver.macro_series

series_id
provider
name
frequency
unit
```

and:

```text
silver.macro_observation

series_id
reference_date
value
published_at
```

Then:

```text
SELIC
IPCA
USD/BRL
IBC-Br
credit
...
```

all use essentially the same schema.

Adding a new BCB series doesn't require creating another pipeline model.

---

# 13. Gold — analytical domain tables

Gold should not resemble source data at all.

I'd organize it around questions.

```text
gold/
│
├── company_daily
├── company_financials
├── company_ratios
│
├── security_performance
├── security_valuation
│
├── sector_daily
├── market_daily
│
├── macro_daily
└── rates_daily
```

For example:

```text
gold.company_financials

company_id
reference_date

revenue_ttm
ebitda_ttm
ebit_ttm
net_income_ttm

cash
gross_debt
net_debt

operating_cash_flow_ttm
capex_ttm
free_cash_flow_ttm
```

Silver contains the accounting observations.

Gold contains the financial concepts people actually ask about.

---

# 14. `gold.company_ratios`

Derived metrics:

```text
company_id
reference_date

revenue_growth_yoy
earnings_growth_yoy

gross_margin
ebitda_margin
net_margin

roe
roic

net_debt_ebitda

pe
price_book
ev_ebitda

fcf_yield
dividend_yield
```

Now CVM fundamentals and B3 market data finally meet.

```text
CVM
 │
 ▼
financial statements
 │
 ├─────────────┐
 │             │
 ▼             ▼
earnings      equity

                  B3
                   │
                   ▼
              market cap
                   │
         ┌─────────┘
         ▼
       P/E
       P/B
       EV/EBITDA
```

That's a natural Gold transformation.

---

# 15. `gold.company_daily` can become the central dataset

Eventually I'd build one particularly useful table:

```text
gold.company_daily
```

Something like:

```text
date
company_id
security_id
ticker

# Market
close
market_cap
return_1d
return_5d
return_1m
return_1y
volatility_20d

# Fundamentals
revenue_ttm
ebitda_ttm
net_income_ttm
free_cash_flow_ttm

# Ratios
pe
ev_ebitda
roe
roic
net_debt_ebitda

# Macro
selic
usdbrl
ipca_12m

# Rates
tesouro_prefixado_1y
tesouro_ipca_rate
```

This shouldn't replace your normalized Silver layer.

It's an **analytical projection** on top of it.

---

# 16. Source → Bronze → Silver → Gold

The important lineage looks like this:

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

Market:

```text
B3
 │
 ▼
bronze.b3_trade_information
 │
 ▼
silver.security_price
 │
 ▼
gold.security_performance
 │
 └──────────────┐
                ▼
       gold.company_ratios
```

Macro:

```text
BCB SGS
   │
   ▼
bronze.bcb_sgs
   │
   ▼
silver.macro_observation
   │
   ▼
gold.macro_daily
```

Rates:

```text
Tesouro
   │
   ▼
bronze.tesouro_rates
   │
   ▼
silver.government_bond_price
   │
   ▼
gold.rates_daily
```

---

# My recommended V1

I would **not** start with 15 sources.

Start with four source families:

```text
             ┌────────── B3 / Market Provider
             │
             ├────────── CVM
             │
SOURCES ─────┼────────── BCB
             │
             └────────── Tesouro
```

They give you almost everything required for a compelling Brazilian financial lakehouse:

**B3 / market provider**
→ stocks, prices, volume, instruments.

**CVM**
→ companies, quarterly/annual fundamentals, disclosures.

**BCB**
→ rates, inflation, FX, macroeconomic conditions.

**Tesouro**
→ Brazilian yield/rate environment.

Then later:

```text
V2 → IBGE
V2 → company IR
V3 → news
V3 → derivatives
V3 → FIIs/funds
V4 → international markets
V4 → alternative data
```

The main architectural principle I'd preserve from day one is:

> **Bronze represents sources. Silver represents the financial world. Gold represents analytical questions.**

That separation is what will make the lakehouse clean and extensible.

Would you like to define the canonical Silver schemas first, or the source-to-Bronze folder and table layout?