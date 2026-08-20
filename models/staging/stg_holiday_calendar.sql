{{ config(materialized='view') }}

-- stg_holiday_calendar
-- Pivots the long-form holiday_calendar seed (multiple rows per date allowed:
-- US / Canada / Company) to exactly ONE row per calendar date, per DIM_DATE
-- spec v2.0 Section 8. calendar_type does not survive this pivot; it is
-- resolved into the explicit output columns below.
-- Grain: one row per date (enforced by tests/assert_stg_holiday_grain.sql).

select
    date,
    coalesce(bool_or(calendar_type = 'US'), false)                        as is_us_holiday,
    max(case when calendar_type = 'US' then event_name end)               as us_holiday_name,
    coalesce(bool_or(calendar_type = 'Canada'), false)                    as is_canada_holiday,
    max(case when calendar_type = 'Canada' then event_name end)           as canada_holiday_name,
    -- false only when a Company row marks the date non-working.
    -- US/Canada rows never affect working days (spec Section 7.4).
    not coalesce(bool_or(calendar_type = 'Company' and is_working_day = 0), false)
                                                                          as is_company_working_day
from {{ ref('holiday_calendar') }}
group by date
