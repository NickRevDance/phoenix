-- EDW-71: per version, the view's budget equals the fact and its actuals equal V_METRICS_SALES_DAILY over the version's coverage to date.
with view_totals as (
    select
          v.forecast_version_key
        , sum(v.budget_net_sales) as budget_net_sales
        , sum(v.actual_net_sales) as actual_net_sales
    from {{ ref('v_budget_vs_actual') }} v
    group by v.forecast_version_key
),

fact_totals as (
    select f.forecast_version_key, sum(f.budget_net_sales) as budget_net_sales
    from {{ ref('fact_budget_sales') }} f
    group by f.forecast_version_key
),

actual_totals as (
    select
          df.forecast_version_key
        , coalesce(sum(s.net_sales_amount_usd), 0) as actual_net_sales
    from {{ ref('dim_forecast') }} df
    left join {{ ref('v_metrics_sales_daily') }} s
        on s.invoice_date between df.coverage_start_date and least(df.coverage_end_date, last_day(current_date()))
    where df.forecast_version_key in (select ft.forecast_version_key from fact_totals ft)
    group by df.forecast_version_key
)

select
      ft.forecast_version_key
    , ft.budget_net_sales as fact_budget
    , vt.budget_net_sales as view_budget
    , act.actual_net_sales as sales_view_actual
    , vt.actual_net_sales as view_actual
from fact_totals ft
left join view_totals vt
    on vt.forecast_version_key = ft.forecast_version_key
left join actual_totals act
    on act.forecast_version_key = ft.forecast_version_key
where vt.forecast_version_key is null
   or abs(ft.budget_net_sales - vt.budget_net_sales) > 0.01
   or abs(coalesce(act.actual_net_sales, 0) - coalesce(vt.actual_net_sales, 0)) > 0.01
