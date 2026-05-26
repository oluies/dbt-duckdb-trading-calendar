{{ config(materialized='ephemeral') }}

-- Daily spine bounded by var('calendar_start_date') ..
-- var('calendar_end_date'). dbt_utils.date_spine is half-open on the
-- end, so with end=2036-01-01 the last row is 2035-12-31.

{{ dbt_utils.date_spine(
    datepart="day",
    start_date="cast('" ~ var('calendar_start_date') ~ "' as date)",
    end_date="cast('"   ~ var('calendar_end_date')   ~ "' as date)"
) }}
