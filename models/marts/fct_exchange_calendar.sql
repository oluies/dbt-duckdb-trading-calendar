{{ config(materialized='table') }}

-- Trading-calendar fact: one row per (calendar_date, exchange_code).
-- The source seed lists only EXCEPTION days (full closures and unusual
-- sessions); ordinary trading days are not enumerated. To answer
-- "is the exchange open on date X?", LEFT JOIN this fact and treat
-- a NULL match as a regular trading day -- subject to weekend logic
-- from dim_date.
--
-- Exchange calendars are maintained manually because they diverge from
-- national public holidays (e.g. Nasdaq Stockholm closes for
-- midsommarafton, which is not a Swedish public holiday).

with seed as (

    select * from {{ ref('exchange_holidays') }}

)

select
    {{ dbt_utils.generate_surrogate_key([
        'calendar_date',
        'exchange_code'
    ]) }}                                                       as exchange_key,
    cast(strftime(cast(calendar_date as date), '%Y%m%d') as integer)
                                                                 as date_key,
    cast(calendar_date as date)                                  as calendar_date,
    exchange_code,
    exchange_name,
    country_code,
    cast(is_trading_day    as boolean)                           as is_trading_day,
    cast(is_settlement_day as boolean)                           as is_settlement_day,
    nullif(holiday_name, '')                                     as holiday_name
from seed
