-- EDW-71 reconciliation gate: per fiscal year, the current legacy budget version's net sales and units in the fact equal
-- the source. A failure after a Finance reload means the budget changed: add a new forecast_version row for it.
with source_fy as (
    select
          d.fiscal_year
        , sum(b.Budget) as net_sales
        , sum(b.BudgetQty) as units
    from {{ ref('silver_dwh_budget_sales_summary_class') }} b
    inner join {{ ref('dim_date') }} d
        on d.date = b.SaleDate
    group by d.fiscal_year
),

current_version as (
    select
          df.fiscal_year
        , df.forecast_version_key
        , row_number() over (partition by df.fiscal_year order by df.version_number desc, df.published_datetime desc nulls last) as version_rank
    from {{ ref('dim_forecast') }} df
    where df.record_source_table = 'dwhvisualnext.analytics.f_BudgetSalesWithSummaryClass'
      and df.forecast_type = 'Annual Budget'
      and df.forecast_status = 'Published'
),

gold_fy as (
    select
          cv.fiscal_year
        , sum(f.budget_net_sales) as net_sales
        , sum(f.budget_units) as units
    from current_version cv
    inner join {{ ref('fact_budget_sales') }} f
        on f.forecast_version_key = cv.forecast_version_key
    where cv.version_rank = 1
    group by cv.fiscal_year
)

select
      coalesce(s.fiscal_year, g.fiscal_year) as fiscal_year
    , s.net_sales as source_net_sales
    , g.net_sales as gold_net_sales
    , s.units as source_units
    , g.units as gold_units
from source_fy s
full outer join gold_fy g
    on g.fiscal_year = s.fiscal_year
where s.fiscal_year is null
   or g.fiscal_year is null
   or abs(s.net_sales - g.net_sales) > 0.01
   or abs(s.units - g.units) > 0.01
