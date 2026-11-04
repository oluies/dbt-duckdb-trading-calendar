{{ config(materialized='table') }}

-- SEK/EUR volatility regimes: one row per segment that PELT finds in the
-- daily log returns. Needs the cpt extension
-- (https://github.com/hugr-lab/duck-changepoint), loaded by the pre-hook
-- in dbt_project.yml (macros/load_cpt.sql) from env var
-- CPT_EXTENSION_PATH.
--
-- cost 'normal' detects changes in mean AND variance, which is what moves
-- in an FX return series: the mean stays near zero while the volatility
-- shifts (COVID spring 2020, the April 2025 tariff shock). The penalty
-- (var cpt_penalty, R changepoint's MBIC by default) and the minimum
-- regime length (var cpt_min_regime_days) set how many breaks survive.
--
-- The series is indexed by fixing day, so a regime's length counts
-- trading days and its dates come straight from the calendar join.
-- Annualised volatility uses 252 trading days per year.

{%- set penalty = var('cpt_penalty') -%}
{#- cpt_pelt takes a named penalty as VARCHAR and a number as DOUBLE -#}
{%- set penalty_sql = penalty if penalty is number else "'" ~ penalty ~ "'" %}

with returns as (

    select date_day, log_return_pct
    from {{ ref('fct_trading_day_fx') }}
    where log_return_pct is not null

),

series as (

    select
        list(log_return_pct order by date_day) as xs,
        list(date_day       order by date_day) as days
    from returns

),

segments as (

    select
        days,
        unnest(cpt_segment_stats(
            xs,
            cpt_pelt(xs, 'normal', {{ penalty_sql }}, {{ var("cpt_min_regime_days") }})
        )) as seg
    from series

)

select
    cast(row_number() over (order by seg.start) as integer)       as regime_number,
    days[seg.start]                                               as start_date,
    days[seg."end"]                                               as end_date,
    cast(strftime(days[seg.start], '%Y%m%d') as integer)          as start_date_key,
    cast(strftime(days[seg."end"], '%Y%m%d') as integer)          as end_date_key,
    seg.n                                                         as trading_days,
    seg.mean                                                      as mean_log_return_pct,
    sqrt(seg.var)                                                 as daily_vol_pct,
    sqrt(seg.var * 252)                                           as annualised_vol_pct
from segments
