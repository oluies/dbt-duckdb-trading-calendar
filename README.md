# dbt-duckdb-trading-calendar

A dbt project that builds a **date dimension** plus a **normalized,
Kimball-style holiday and exchange calendar** in SQL Server 2022,
using **DuckDB** (via `dbt-duckdb`) as the compute engine.

DuckDB reads the public Azure Open Datasets _Public Holidays_ Parquet
directly from blob storage and writes the resulting tables into a
SQL Server database (`Referensdata.azuredl`) over the DuckDB **mssql**
extension's `ATTACH`.

---

## Setup

### 1. Prerequisites

- Docker (with `docker compose`)
- Python 3.10+
- On macOS the default compose file uses the official
  `mcr.microsoft.com/mssql/server:2022-latest` image which is linux/amd64.
  On Apple Silicon you can either let Docker Desktop emulate it via
  Rosetta, **or** pass `PLATFORM=arm-mac` to use the native arm64
  Azure SQL Edge image (see below).

### 2. Configure the SA password

```bash
cp .env.example .env
# edit .env -- replace SA_PASSWORD with something strong, e.g.:
#   openssl rand -base64 32 | tr -d '/+=' | cut -c1-24
```

The password must satisfy SQL Server's complexity rules (>= 8 chars,
contains three of: upper, lower, digit, non-alphanumeric).
`.env` is gitignored.

### 3. Start SQL Server and create the database + schema

**Default (linux/amd64 — works on Linux and via Rosetta on Macs):**

```bash
make db-up
make db-init
```

**Apple Silicon native (Azure SQL Edge, linux/arm64):**

```bash
make PLATFORM=arm-mac db-up
make PLATFORM=arm-mac db-init
```

> Caveat: Azure SQL Edge has been announced end-of-support by Microsoft
> (Sep 2025). It remains the only native arm64 option for dev as of
> 2026, and `dbt-duckdb`'s mssql ATTACH talks to it over the same wire
> protocol unchanged. Don't use it for production.

`db-init` creates a `Referensdata` database and an `azuredl` schema.
dbt creates and drops the **tables** inside that schema; the schema
itself is created here so no model needs `CREATE SCHEMA` privileges.

### 4. Install dbt and run

```bash
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

# profiles.yml lives in the repo root; tell dbt to look there.
export DBT_PROFILES_DIR=$PWD

dbt deps
dbt seed
dbt run
dbt test
```

The full end-to-end sequence:

```bash
make db-up && make db-init && \
  dbt deps && dbt seed && dbt run && dbt test
```

(prefix the `make` commands with `PLATFORM=arm-mac` on Apple Silicon).

---

## Data model

Normalized, Kimball-style. **No** wide per-country boolean columns on
`dim_date`.

```
                          +--------------------+
                          |     dim_date       |
                          |--------------------|
                          | date_key  (PK)     |
                          | date_day           |
                          | year/quarter/month |
                          | day_of_year        |
                          | iso_week_number    |
                          | iso_day_of_week    |  (1=Mon..7=Sun)
                          | month_name         |
                          | day_name           |
                          | first/last_of_month|
                          | is_weekend         |
                          +---------+----------+
                                    ^
                                    | date_key
              +---------------------+---------------------+
              |                                           |
   +----------+-------------+                +-----------+-----------+
   | fct_holiday_calendar   |                | fct_exchange_calendar |
   |------------------------|                |-----------------------|
   | holiday_key  (PK, sk)  |                | exchange_key (PK, sk) |
   | date_key      (FK)     |                | date_key      (FK)    |
   | country_code  (FK)     |                | calendar_date         |
   | holiday_date           |                | exchange_code         |
   | holiday_name           |                | exchange_name         |
   | is_observed            |                | country_code  (FK)    |
   | is_paid_time_off       |                | is_trading_day        |
   | holiday_type           |                | is_settlement_day     |
   +-----------+------------+                | holiday_name (nullable)
               |                             +-----------+-----------+
               | country_code                            |
               v                                         | country_code
       +---------------+                                 |
       |  dim_country  |<--------------------------------+
       |---------------|
       | country_code  (PK, ISO 3166-1 alpha-2)
       | country_name
       +---------------+
```

- **`stg_public_holidays`** – staging view of the Azure parquet, filtered
  to the country codes in `var('holiday_country_codes')`.
- **`stg_date_spine`** – ephemeral daily spine 2015-01-01 .. 2035-12-31
  from `dbt_utils.date_spine`.
- **`dim_date`** – country-agnostic, one row per day. `iso_day_of_week`
  uses DuckDB's `isodow()`, which always returns 1=Monday..7=Sunday and
  does NOT depend on any `SET DATEFIRST` / locale setting. ISO 8601
  week semantics are completed by `iso_week_number`, `iso_year`, and
  the text key `iso_year_week` ('2026-W01').

  Includes **ML feature columns** alongside the standard dim columns:

  - cycle-position booleans: `is_month_start`, `is_month_end`,
    `is_quarter_start`, `is_quarter_end`, `is_year_start`, `is_year_end`,
    plus `week_of_month` (1..5).
  - distance integers: `days_since_year_start`, `days_to_year_end`
    (both 0 on their boundary day).
  - cyclical encodings: `dow_sin/cos`, `month_sin/cos`, `doy_sin/cos`.
    Each `(sin, cos)` pair maps an ordinal onto the unit circle so the
    first and last value of the cycle sit adjacent (Sun -> Mon = 1 step,
    Dec -> Jan = 1 step) instead of being maximally apart. Useful for
    linear models, and as input features for tree models that don't
    natively model cycles. Day-of-year uses period 365.25 to average
    across the leap cycle. See scikit-learn's [Time-related feature
    engineering](https://scikit-learn.org/stable/auto_examples/applications/plot_cyclical_feature_engineering.html)
    example for the canonical pattern.

  We deliberately do NOT one-hot day_name / month_name / quarter into
  the dim -- modern ML frameworks accept integers, and one-hot at the
  warehouse layer couples the schema to a specific feature pipeline.
- **`dim_country`** – seeded from `seeds/dim_country.csv`. One row per
  country in `var('holiday_country_codes')`.
- **`fct_holiday_calendar`** – grain `(holiday_date, country_code)`.
  Surrogate `holiday_key` via `dbt_utils.generate_surrogate_key`.
  `holiday_type` always equals `'public_holiday'` for Azure rows; the
  column exists so de-facto / bank holidays can be unioned in later.
- **`fct_exchange_calendar`** – grain `(calendar_date, exchange_code)`.
  Seeded from `seeds/exchange_holidays.csv`. Lists **exception days
  only** (full closures + half-day sessions); ordinary trading days
  are inferred from "no row" plus `dim_date.is_weekend`.

The seed is pre-populated with **Nasdaq Stockholm (XSTO)** exception
days for 2024–2026 as a worked example.

### Why normalized?

- **Scales to N countries with no schema change.** Wide per-country
  boolean columns (`is_holiday_se`, `is_holiday_no`, …) require a
  schema migration every time a new country is added and force a
  costly join-by-pivot for "what's a holiday today across our markets?"
- **Plays nicely with exchange calendars.** National public holidays
  and exchange closures aren't the same set — Swedish exchanges close
  on **midsommarafton** (not a Swedish public holiday) and trade
  half-days on certain eves. They need their own fact table; a
  per-country boolean on `dim_date` can't express that.
- **Future-proof for subdivision calendars.** Adding ISO 3166-2 level
  data (state/canton/county holidays) is a straight repeat of the same
  pattern: a `dim_subdivision` table keyed `(country_code,
  subdivision_code)` and a `fct_subdivision_holiday` fact with grain
  `(holiday_date, country_code, subdivision_code)`. Not built here;
  noted for later.

---

## Tests (`dbt test`)

`models/schema.yml` covers:

- `dim_date` – unique + not_null on `date_key`, `date_day`;
  `iso_day_of_week` in 1..7
- `dim_country` – unique + not_null on `country_code`;
  `accepted_values` matching `var('holiday_country_codes')`
- `fct_holiday_calendar` – not_null on `date_key`, `country_code`,
  `holiday_date`; unique combination `(holiday_date, country_code)`;
  relationships to `dim_date` and `dim_country`;
  `accepted_values` on `holiday_type`
- `fct_exchange_calendar` – unique combination `(calendar_date,
  exchange_code)`; relationships on `date_key` and `country_code`

---

## Observability (Elementary OSS)

The [`elementary-data/elementary`](https://docs.elementary-data.com/oss/oss-introduction)
package is wired up but **disabled by default**. The
`.github/workflows/elementary.yml` workflow flips the gating var
(`with_elementary: true`), builds elementary's tables into
`Referensdata.elementary`, and publishes the resulting HTML report
(models, tests, lineage, run history) as a workflow artifact.

Triggered manually (`workflow_dispatch`), on push to `main`, and on a
weekly schedule. The main `ci.yml` is unaffected.

To generate locally:

```bash
pip install -r requirements-elementary.txt
dbt deps
dbt seed --vars '{with_elementary: true}'
dbt run  --vars '{with_elementary: true}'
dbt test --vars '{with_elementary: true}' || true
dbt run  --select package:elementary --vars '{with_elementary: true}'
edr report --profiles-dir "$PWD" --profile-target dev \
  --file-path elementary-report/index.html
open elementary-report/index.html
```

You'll need to pre-create the schema once:

```sql
USE Referensdata;
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'elementary')
    EXEC('CREATE SCHEMA elementary');
```

---

## Notes / decisions

### Source of holiday data

The project ships with the **Azure Open Datasets _Public Holidays_**
parquet. License: **CC BY-SA 3.0 (ShareAlike)**. It's a frozen
**1970–2099 snapshot** maintained by Microsoft, originally derived
from the same underlying Python `holidays` package.

The MIT-licensed [`holidays`](https://pypi.org/project/holidays/) PyPI
package is the same upstream source but is _current_ rather than
frozen, and would be a defensible swap if you need:

- continuously updated holiday data after the frozen snapshot ages,
- a more permissive license (MIT vs. CC BY-SA 3.0),
- subdivision-level (ISO 3166-2) holidays out of the box.

To swap: replace `stg_public_holidays.sql` with a Python model
(dbt-duckdb supports Python models) that imports `holidays`, builds
a DataFrame keyed `(country_code, date)`, and exposes the same
columns. The downstream model (`fct_holiday_calendar`) doesn't need
to change. We've kept the Azure source here because the requirement
calls for it; the rest of the pipeline is source-agnostic.

### iso_day_of_week and SET DATEFIRST

SQL Server's `DATEPART(weekday, …)` depends on the connection's
`SET DATEFIRST` value, which makes any column computed from it
non-portable. We compute `iso_day_of_week` in DuckDB using `isodow()`,
which is locale-independent and standards-aligned (ISO 8601:
1=Monday..7=Sunday). The integer is then written into SQL Server
as plain `INT`, so consumers can read it without ever issuing a
`SET DATEFIRST`.

### Schema management

- The schema `Referensdata.azuredl` is created by `make db-init` and
  is NOT created by any dbt model. dbt only manages **tables** inside
  it (create/drop). This avoids the SA-only-on-bootstrap surprise of
  bare `CREATE SCHEMA` statements inside models.

### Future extensions

- `dim_subdivision` + `fct_subdivision_holiday` keyed on
  `(country_code, subdivision_code)` for ISO 3166-2 sub-national
  calendars (German Länder, US states, UK constituent countries with
  separate bank holidays). Same shape as the country pair; not built
  now.
- A `dim_exchange` would naturally pair with the existing exchange
  fact once more than one exchange is in scope.

---

## Repo layout

```
.
├── .env.example              # template; copy to .env and edit
├── .gitignore
├── docker-compose.yml        # default (linux/amd64 SQL Server 2022)
├── docker-compose.arm.yml    # PLATFORM=arm-mac (linux/arm64 Azure SQL Edge)
├── Makefile                  # db-up / db-down / db-shell / db-init
├── requirements.txt          # dbt-core, dbt-duckdb
├── packages.yml              # dbt_utils
├── dbt_project.yml
├── profiles.yml              # uses DBT_PROFILES_DIR=$PWD
├── models/
│   ├── schema.yml
│   ├── staging/
│   │   ├── stg_public_holidays.sql
│   │   └── stg_date_spine.sql
│   └── marts/
│       ├── dim_date.sql
│       ├── fct_holiday_calendar.sql
│       └── fct_exchange_calendar.sql
└── seeds/
    ├── dim_country.csv
    └── exchange_holidays.csv
```
