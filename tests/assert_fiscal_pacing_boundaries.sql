-- Spec v2.1 Section 8, test 8: calendar-day pacing derives from true fiscal
-- period boundaries, so the two fiscal years truncated by the table range
-- (FY2005 begins 2004-07-01, FY2037 ends 2037-06-30) pace correctly.
--   - fiscal_year_total_days is 365 or 366 for every fiscal year present.
--   - fiscal_days_elapsed on 2005-01-01 is 185 (Jul 1 2004 to Jan 1 2005).
--   - fiscal_year_pct_complete increases strictly within a fiscal year and
--     reaches exactly 1.0000 on June 30 of every fully contained fiscal year.
-- Excludes the reserved unknown member (date_key = -1), whose pacing is null.

with d as (
    select
        date,
        fiscal_year,
        fiscal_year_total_days,
        fiscal_days_elapsed,
        fiscal_year_pct_complete,
        lag(fiscal_year_pct_complete) over (partition by fiscal_year order by date) as prior_pct
    from {{ ref('dim_date') }}
    where date_key <> {{ unknown_member_key() }}
)

select date, fiscal_year, fiscal_year_total_days, fiscal_days_elapsed, fiscal_year_pct_complete, prior_pct
from d
where fiscal_year_total_days not in (365, 366)
   or (date = to_date('2005-01-01') and fiscal_days_elapsed <> 185)
   or (prior_pct is not null and fiscal_year_pct_complete <= prior_pct)
   or (month(date) = 6 and day(date) = 30 and fiscal_year between 2006 and 2036
       and fiscal_year_pct_complete <> 1.0000)