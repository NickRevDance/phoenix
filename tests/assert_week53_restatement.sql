-- Spec Section 8, test 6 (part 2): in the year following a 53-week retail
-- year, restated week 52 maps to original week 53 of the prior retail year.

with d as (
    select date, retail_year, retail_week, comparable_date_ly
    from {{ ref('dim_date') }}
)
select a.date, a.retail_year, a.retail_week, a.comparable_date_ly, b.retail_week as prior_year_week
from d a
inner join d b
    on b.date = a.comparable_date_ly
inner join {{ ref('retail_calendar_years') }} p
    on p.retail_year = a.retail_year - 1
where a.retail_week = 52
  and p.weeks_in_retail_year = 53
  and (b.retail_week <> 53 or b.retail_year <> a.retail_year - 1)
