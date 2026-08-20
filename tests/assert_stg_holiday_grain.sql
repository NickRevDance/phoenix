-- Spec Section 8, test 4: holiday staging grain. The pivot output must be
-- unique on date so the DIM_DATE join cannot multiply rows.

select date, count(*) as n
from {{ ref('stg_holiday_calendar') }}
group by date
having count(*) > 1
