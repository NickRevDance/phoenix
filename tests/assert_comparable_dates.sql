-- Spec Section 8, test 6 (part 1): comparable dates, NRF restated methodology.
--   - Retail week 53 comparable-date fields are NULL (all three).
--   - Non-NULL offsets are exactly -364 / -728 / -1092 days (weekday preserved
--     by construction since the offsets are multiples of 7).
--   - NULLs outside week 53 occur only when the offset lands before 2005-01-01.
--   - Spot check: 2026-08-11 -> 2025-08-12 / 2024-08-13 / 2023-08-15.

select date, retail_week, comparable_date_ly, comparable_date_2ly, comparable_date_3ly
from {{ ref('dim_date') }}
where (retail_week = 53 and (comparable_date_ly  is not null
                          or comparable_date_2ly is not null
                          or comparable_date_3ly is not null))

   or (retail_week <> 53 and comparable_date_ly  is not null and datediff(day, comparable_date_ly,  date) <> 364)
   or (retail_week <> 53 and comparable_date_2ly is not null and datediff(day, comparable_date_2ly, date) <> 728)
   or (retail_week <> 53 and comparable_date_3ly is not null and datediff(day, comparable_date_3ly, date) <> 1092)

   or (retail_week <> 53 and comparable_date_ly  is null and dateadd(day, -364,  date) >= to_date('2005-01-01'))
   or (retail_week <> 53 and comparable_date_2ly is null and dateadd(day, -728,  date) >= to_date('2005-01-01'))
   or (retail_week <> 53 and comparable_date_3ly is null and dateadd(day, -1092, date) >= to_date('2005-01-01'))

   or (date = to_date('2026-08-11') and (comparable_date_ly  <> to_date('2025-08-12')
                                      or comparable_date_2ly <> to_date('2024-08-13')
                                      or comparable_date_3ly <> to_date('2023-08-15')))
