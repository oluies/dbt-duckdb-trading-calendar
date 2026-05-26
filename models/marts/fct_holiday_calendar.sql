{{ config(materialized='table') }}

-- Holiday fact: one row per (holiday_date, country_code).
-- holiday_type defaults to 'public_holiday' for everything sourced from
-- the Azure Open Datasets feed. The column exists so de-facto or bank-
-- specific holidays can be unioned in later without a schema change.

with holidays as (

    select * from {{ ref('stg_public_holidays') }}

)

select
    {{ dbt_utils.generate_surrogate_key([
        'holiday_date',
        'country_region_code'
    ]) }}                                                       as holiday_key,
    cast(strftime(holiday_date, '%Y%m%d') as integer)           as date_key,
    country_region_code                                          as country_code,
    holiday_date,
    holiday_name,
    cast(true as boolean)                                        as is_observed,
    cast(is_paid_time_off as boolean)                            as is_paid_time_off,
    cast('public_holiday' as varchar)                            as holiday_type
from holidays
