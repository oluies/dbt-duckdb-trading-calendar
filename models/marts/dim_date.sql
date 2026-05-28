{{ config(materialized='table') }}

-- Country-agnostic calendar dimension. Holds NO holiday columns;
-- "is X a holiday in country Y" is answered by joining
-- fct_holiday_calendar on date_key + country_code.
--
-- iso_day_of_week uses DuckDB's isodow() which always returns
-- 1 (Monday) .. 7 (Sunday) and is INDEPENDENT of any
-- SET DATEFIRST / locale setting. iso_year + iso_year_week follow
-- ISO 8601 too: 2025-12-29 -> iso_year=2026, iso_year_week='2026-W01'.
--
-- ML feature columns (cycle-position booleans, distance ints,
-- sin/cos cyclical encodings) live alongside the standard dim
-- columns so feature-engineering pipelines can read straight from
-- this one table without re-deriving from date_day.

with base as (

    select
        cast(date_day as date)                                        as date_day,
        cast(strftime(date_day, '%Y%m%d') as integer)                 as date_key,
        cast(extract(year     from date_day) as integer)              as year_number,
        cast(extract(quarter  from date_day) as integer)              as quarter_number,
        cast(extract(month    from date_day) as integer)              as month_number,
        cast(extract(day      from date_day) as integer)              as day_of_month,
        cast(extract(doy      from date_day) as integer)              as day_of_year,
        cast(extract(week     from date_day) as integer)              as iso_week_number,
        cast(extract(isoyear  from date_day) as integer)              as iso_year,
        strftime(date_day, '%G-W%V')                                  as iso_year_week,
        strftime(date_day, '%B')                                      as month_name,
        strftime(date_day, '%A')                                      as day_name,
        cast(isodow(date_day) as integer)                             as iso_day_of_week,
        cast(date_trunc('month',   date_day) as date)                 as first_day_of_month,
        cast(last_day(date_day) as date)                              as last_day_of_month,
        cast(date_trunc('quarter', date_day) as date)                 as first_day_of_quarter,
        cast(date_trunc('quarter', date_day) + interval 3 month - interval 1 day as date)
                                                                       as last_day_of_quarter,
        cast(date_trunc('year',    date_day) as date)                 as first_day_of_year,
        cast(date_trunc('year',    date_day) + interval 1 year - interval 1 day as date)
                                                                       as last_day_of_year
    from {{ ref('stg_date_spine') }}

)

select
    date_key,
    date_day,
    year_number,
    quarter_number,
    month_number,
    day_of_month,
    day_of_year,
    iso_week_number,
    iso_year,
    iso_year_week,
    month_name,
    day_name,
    iso_day_of_week,
    first_day_of_month,
    last_day_of_month,
    first_day_of_quarter,
    last_day_of_quarter,
    first_day_of_year,
    last_day_of_year,
    case when iso_day_of_week >= 6 then true else false end           as is_weekend,

    -- Cycle-position flags. Genuine ML signals (billing cycles,
    -- reporting effects, seasonality phase) -- not redundant
    -- expansions of the integer columns above.
    cast(day_of_month  = 1                     as boolean)            as is_month_start,
    cast(date_day      = last_day_of_month     as boolean)            as is_month_end,
    cast(date_day      = first_day_of_quarter  as boolean)            as is_quarter_start,
    cast(date_day      = last_day_of_quarter   as boolean)            as is_quarter_end,
    cast(date_day      = first_day_of_year     as boolean)            as is_year_start,
    cast(date_day      = last_day_of_year      as boolean)            as is_year_end,
    cast((day_of_month - 1) / 7 + 1 as integer)                       as week_of_month,

    -- Distance features (integers, both 0 on their boundary day).
    cast(day_of_year - 1 as integer)                                  as days_since_year_start,
    cast(date_diff('day', date_day, last_day_of_year) as integer)     as days_to_year_end,

    -- Cyclical encodings: each ordinal is mapped onto the unit
    -- circle so the first and last value of the cycle are adjacent
    -- (Sun->Mon = 1 step, Dec->Jan = 1 step) instead of being the
    -- maximum distance apart. Tree models can split on either column;
    -- linear models read the pair as a smooth function of cycle phase.
    -- Use (n-1)/period so n=1 lands at angle 0. Day-of-year uses
    -- 365.25 to average across the leap cycle.
    --
    -- Reference: scikit-learn's "Time-related feature engineering"
    -- example (sin/cos for hour, weekday, month):
    -- https://scikit-learn.org/stable/auto_examples/applications/plot_cyclical_feature_engineering.html
    sin(2 * pi() * (iso_day_of_week - 1) / 7.0)                       as dow_sin,
    cos(2 * pi() * (iso_day_of_week - 1) / 7.0)                       as dow_cos,
    sin(2 * pi() * (month_number    - 1) / 12.0)                      as month_sin,
    cos(2 * pi() * (month_number    - 1) / 12.0)                      as month_cos,
    sin(2 * pi() * (day_of_year     - 1) / 365.25)                    as doy_sin,
    cos(2 * pi() * (day_of_year     - 1) / 365.25)                    as doy_cos
from base
