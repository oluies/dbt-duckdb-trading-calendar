{{ config(enabled=var('with_changepoint', false), tags=['changepoint']) }}

-- Domain check on the detector: days of known FX stress must fall in a
-- regime whose volatility is at least twice the median regime's. A
-- penalty or minimum length that merges these episodes into calm
-- regimes fails here.
--   2020-03-16  COVID-19 sell-off
--   2025-04-07  global sell-off after the US tariff announcement

with regimes as (

    select * from {{ ref('fct_fx_regimes') }}

),

median_vol as (

    select median(annualised_vol_pct) as vol from regimes

),

stress_dates as (

    select cast(d as date) as date_day
    from (values ('2020-03-16'), ('2025-04-07')) as t(d)

)

select s.date_day, r.regime_number, r.annualised_vol_pct, m.vol as median_vol
from stress_dates as s
cross join median_vol as m
left join regimes as r
       on s.date_day between r.start_date and r.end_date
where r.regime_number is null
   or r.annualised_vol_pct < 2 * m.vol
