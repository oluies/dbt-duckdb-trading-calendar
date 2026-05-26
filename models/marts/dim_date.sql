{{ config(materialized='table') }}

-- Country-agnostic calendar dimension. Holds NO holiday columns;
-- "is X a holiday in country Y" is answered by joining
-- fct_holiday_calendar on date_key + country_code.
--
-- iso_day_of_week uses DuckDB's isodow() which always returns
-- 1 (Monday) .. 7 (Sunday) and is INDEPENDENT of any
-- SET DATEFIRST / locale setting.

select
    cast(strftime(date_day, '%Y%m%d') as integer)                    as date_key,
    cast(date_day as date)                                            as date_day,
    cast(extract(year     from date_day) as integer)                  as year_number,
    cast(extract(quarter  from date_day) as integer)                  as quarter_number,
    cast(extract(month    from date_day) as integer)                  as month_number,
    cast(extract(day      from date_day) as integer)                  as day_of_month,
    cast(extract(doy      from date_day) as integer)                  as day_of_year,
    cast(extract(week     from date_day) as integer)                  as iso_week_number,
    strftime(date_day, '%B')                                          as month_name,
    strftime(date_day, '%A')                                          as day_name,
    cast(isodow(date_day) as integer)                                 as iso_day_of_week,
    cast(date_trunc('month', date_day) as date)                       as first_day_of_month,
    cast(last_day(date_day) as date)                                  as last_day_of_month,
    case when isodow(date_day) >= 6 then true else false end          as is_weekend
from {{ ref('stg_date_spine') }}
