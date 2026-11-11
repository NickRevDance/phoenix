{{ config(severity = 'warn') }}

-- EDW-71: a budget month should never be negative (spec section 7); daily negatives in the source net out and are not flagged.
select
      f.forecast_version_key
    , f.budget_month_date
    , f.summary_class
    , f.budget_net_sales
    , f.budget_units
from {{ ref('fact_budget_sales') }} f
where f.budget_net_sales < 0
   or f.budget_units < 0
