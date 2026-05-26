{{ config(materialized='table') }}

-- Reads Azure Open Datasets "Public Holidays" parquet directly from blob
-- storage (anonymous access via the azure secret configured in profiles.yml)
-- and filters down to the country list configured in dbt_project.yml.

with source as (

    select *
    from read_parquet(
        'azure://holidaydatacontainer/Processed/*.parquet'
    )
    where countryRegionCode in (
        {%- for code in var('holiday_country_codes') -%}
            '{{ code }}'{% if not loop.last %}, {% endif %}
        {%- endfor -%}
    )
      -- Clip to the same horizon as the date spine. The upstream
      -- parquet is a 1970-2099 snapshot; rows outside the spine have
      -- no matching dim_date row and would fail the
      -- fct_holiday_calendar -> dim_date relationships test.
      and cast(date as date) >= cast('{{ var("calendar_start_date") }}' as date)
      and cast(date as date) <  cast('{{ var("calendar_end_date")   }}' as date)

)

select
    countryRegionCode               as country_region_code,
    countryOrRegion                 as country_or_region,
    cast(date as date)              as holiday_date,
    holidayName                     as holiday_name,
    normalizeHolidayName            as holiday_name_normalized,
    isPaidTimeOff                   as is_paid_time_off
from source
