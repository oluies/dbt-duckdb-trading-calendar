{{ config(enabled=var('with_changepoint', false), tags=['changepoint']) }}

-- Within years the exchange_holidays seed covers, the Riksbank publishes
-- a SEK/EUR fixing exactly on Nasdaq Stockholm trading days. A row here
-- is a date where the two calendars disagree: either the seed is missing
-- a closure (a trading day without a fixing) or lists a closure the
-- banking calendar does not have (a fixing on a closed day).
--
-- This test found New Year's Eve, which the seed carried as a half-day
-- session; Nasdaq Stockholm is closed on 31 December.

select date_day, is_xsto_trading_day, has_fixing
from {{ ref('fct_trading_day_fx') }}
where is_xsto_trading_day is not null
  and is_xsto_trading_day <> has_fixing
