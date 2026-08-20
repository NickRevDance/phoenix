-- Spec Section 8, test 3: 53-week retail years within range are exactly
-- 2006, 2012, 2017, 2023, 2028, 2034. Years covered by a published NRF
-- calendar are validated against NRF directly; later years follow the NRF
-- generation rule and are revalidated as NRF publishes.

select retail_year, weeks_in_retail_year
from {{ ref('retail_calendar_years') }}
where (weeks_in_retail_year = 53)
   <> (retail_year in (2006, 2012, 2017, 2023, 2028, 2034))
