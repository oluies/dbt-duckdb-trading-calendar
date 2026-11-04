{{ config(enabled=var('with_changepoint', false), tags=['changepoint']) }}

-- The regimes partition the return series: the first starts on the first
-- return, each next one starts on the fixing day after the previous end,
-- the last ends on the final return, and the lengths add up to the
-- number of returns. Returns one row per violation.

with returns as (

    select
        date_day,
        row_number() over (order by date_day) as obs
    from {{ ref('fct_trading_day_fx') }}
    where log_return_pct is not null

),

regimes as (

    select
        r.regime_number,
        r.trading_days,
        s.obs as start_obs,
        e.obs as end_obs,
        lag(e.obs) over (order by r.regime_number) as prev_end_obs
    from {{ ref('fct_fx_regimes') }} as r
    join returns as s on s.date_day = r.start_date
    join returns as e on e.date_day = r.end_date

)

select regime_number, 'not contiguous' as problem
from regimes
where start_obs <> coalesce(prev_end_obs, 0) + 1

union all

select regime_number, 'length mismatch'
from regimes
where end_obs - start_obs + 1 <> trading_days

union all

select null, 'does not end on the last return'
where (select max(end_obs) from regimes) <> (select count(*) from returns)

union all

select null, 'missing regimes (a start or end date is not a return date)'
where (select count(*) from regimes) <> (select count(*) from {{ ref('fct_fx_regimes') }})
