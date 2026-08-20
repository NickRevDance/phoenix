-- Spec Section 8, test 2: retail_calendar_years seed integrity.
-- Every start is a Sunday, every end is a Saturday, years are contiguous,
-- weeks in (52, 53), and day span matches the week count.
-- Weekday checks use anchor arithmetic (2005-01-02 was a Sunday) so the test
-- does not depend on dialect week functions.

with s as (
    select
        *,
        lag(retail_year_end_date) over (order by retail_year) as prev_end_date
    from {{ ref('retail_calendar_years') }}
)
select *
from s
where ((datediff(day, to_date('2005-01-02'), retail_year_start_date) % 7) + 7) % 7 <> 0
   or ((datediff(day, to_date('2005-01-02'), retail_year_end_date)   % 7) + 7) % 7 <> 6
   or weeks_in_retail_year not in (52, 53)
   or datediff(day, retail_year_start_date, retail_year_end_date) + 1 <> weeks_in_retail_year * 7
   or (prev_end_date is not null and retail_year_start_date <> dateadd(day, 1, prev_end_date))
   or is_53_week_retail_year <> case when weeks_in_retail_year = 53 then 1 else 0 end
