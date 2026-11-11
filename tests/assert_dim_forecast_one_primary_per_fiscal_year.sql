{{ config(severity = 'warn') }}

-- EDW-70 acceptance criteria: exactly one primary version per fiscal year that has a published budget or reforecast, and none elsewhere.
select
      df.fiscal_year
    , sum(df.is_primary_version) as primary_versions
    , sum(case when df.forecast_status = 'Published' and df.forecast_type in ('Annual Budget', 'Periodic Reforecast') then 1 else 0 end) as published_plans
from {{ ref('dim_forecast') }} df
group by df.fiscal_year
having sum(df.is_primary_version) <> case when sum(case when df.forecast_status = 'Published' and df.forecast_type in ('Annual Budget', 'Periodic Reforecast') then 1 else 0 end) > 0 then 1 else 0 end
