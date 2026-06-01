-- Regression test for dim_date week columns.
--
-- seeds/expected_week_numbers.csv holds frozen, hand-verified values
-- for well-known edge-case dates (ISO 8601 week-year rollover, the two
-- 53-week ISO years 2015 & 2020, and the US/Sunday-start "week 0"
-- convention). Because the expected values are literals checked against
-- published ISO / Swedish veckonummer calendars -- not recomputed -- any
-- change to the week expressions in dim_date.sql is caught here.
--
-- Singular test: passes when it returns zero rows. LEFT JOIN so a
-- reference date missing from dim_date (e.g. spine range shrank) also
-- fails instead of being silently skipped.

with expected as (
    select * from {{ ref('expected_week_numbers') }}
),

actual as (
    select
        date_day,
        iso_week_number,
        iso_year,
        iso_year_week,
        us_week_number
    from {{ ref('dim_date') }}
)

select
    e.date_day,
    e.note,
    e.iso_week_number as expected_iso_week_number,
    a.iso_week_number as actual_iso_week_number,
    e.iso_year        as expected_iso_year,
    a.iso_year        as actual_iso_year,
    e.iso_year_week   as expected_iso_year_week,
    a.iso_year_week   as actual_iso_year_week,
    e.us_week_number  as expected_us_week_number,
    a.us_week_number  as actual_us_week_number
from expected e
left join actual a using (date_day)
where e.iso_week_number is distinct from a.iso_week_number
   or e.iso_year        is distinct from a.iso_year
   or e.iso_year_week   is distinct from a.iso_year_week
   or e.us_week_number  is distinct from a.us_week_number
