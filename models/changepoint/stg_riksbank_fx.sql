{{ config(materialized='table') }}

-- Riksbank daily SEK/EUR fixing (series SEKEURPMI), one row per
-- publication day, with the day-over-day log return in percent.
-- The Riksbank publishes only on Swedish banking days, so the gaps
-- between rows are weekends and bank holidays -- the return is taken
-- between consecutive fixings, not consecutive calendar days.
-- Seed refreshed by scripts/fetch_riksbank_fx.py.

with seed as (

    select * from {{ ref('riksbank_sekeur') }}

)

select
    cast(rate_date as date)                                       as rate_date,
    cast(strftime(cast(rate_date as date), '%Y%m%d') as integer)  as date_key,
    cast(sek_per_eur as double)                                   as sek_per_eur,
    100 * ln(sek_per_eur / lag(sek_per_eur) over (order by rate_date))
                                                                   as log_return_pct
from seed
