{{ config(materialized='ephemeral') }}

-- Daily spine 2015-01-01 .. 2036-01-01. dbt_utils.date_spine is half-open
-- on the end, so the last row is 2035-12-31.

{{ dbt_utils.date_spine(
    datepart="day",
    start_date="cast('2015-01-01' as date)",
    end_date="cast('2036-01-01' as date)"
) }}
