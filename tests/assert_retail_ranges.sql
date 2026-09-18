-- Spec Section 8, test 5: every date joins to exactly one retail year
-- (inner join + row-count test covers "at least one"; this covers ranges),
-- retail_week between 1 and weeks_in_retail_year, retail_period 1-12.
-- Excludes the reserved unknown-member row (date_key = -1, EDW-94 A4 fast-follow,
-- added 2026-09-18) -- its retail attributes are deliberately null, it is not
-- a real calendar date.

select date, retail_year, retail_week, retail_period
from {{ ref('dim_date') }}
where date_key <> {{ unknown_member_key() }}
  and (
        retail_year is null
     or retail_week < 1
     or retail_week > retail_weeks_in_year
     or retail_period < 1
     or retail_period > 12
     or retail_week_in_period < 1
     or retail_week_in_period > 5
     or date < retail_year_start_date
     or date > retail_year_end_date
  )
