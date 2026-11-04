{{ config(materialized='table') }}

-- One row per weekday across the span of the FX series, joined to the
-- Nasdaq Stockholm (XSTO) exception calendar and to the Riksbank fixing.
--
-- is_xsto_trading_day is NULL for years the exchange_holidays seed does
-- not cover: the seed lists exception days only, so an uncovered year
-- would otherwise look like "open every weekday". Inside covered years
-- every XSTO trading day should carry a fixing and every closure should
-- not; tests/assert_fx_fixings_match_xsto_calendar.sql checks that.

with fx as (

    select * from {{ ref('stg_riksbank_fx') }}

),

xsto as (

    select calendar_date, is_trading_day
    from {{ ref('fct_exchange_calendar') }}
    where exchange_code = 'XSTO'

),

covered_years as (

    select distinct year(calendar_date) as year_number from xsto

),

weekdays as (

    select d.date_key, d.date_day, d.year_number
    from {{ ref('dim_date') }} as d
    where not d.is_weekend
      and d.date_day between (select min(rate_date) from fx)
                         and (select max(rate_date) from fx)

)

select
    w.date_key,
    w.date_day,
    case
        when cy.year_number is null then null
        else coalesce(x.is_trading_day, true)
    end                                                          as is_xsto_trading_day,
    fx.rate_date is not null                                     as has_fixing,
    fx.sek_per_eur,
    fx.log_return_pct
from weekdays as w
left join covered_years as cy on cy.year_number = w.year_number
left join xsto          as x  on x.calendar_date = w.date_day
left join fx                  on fx.rate_date    = w.date_day
