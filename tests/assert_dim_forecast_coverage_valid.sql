-- EDW-70 (spec 3.4, 6): coverage inside the target fiscal year, actuals cutoff inside coverage, budgets carry no actuals.
select
      df.forecast_version_id
    , df.fiscal_year
    , df.coverage_start_date
    , df.coverage_end_date
    , df.actuals_through_date
    , df.forecast_start_date
from {{ ref('dim_forecast') }} df
left join {{ ref('dim_date') }} ds on ds.date = df.coverage_start_date
left join {{ ref('dim_date') }} de on de.date = df.coverage_end_date
where df.coverage_start_date > df.coverage_end_date
   or ds.fiscal_year is distinct from df.fiscal_year
   or de.fiscal_year is distinct from df.fiscal_year
   or df.actuals_through_date < df.coverage_start_date
   or df.actuals_through_date >= df.coverage_end_date
   or (df.forecast_type = 'Annual Budget' and df.actuals_through_date is not null)
   or (df.forecast_type = 'Periodic Reforecast' and df.actuals_through_date is null)
   or df.forecast_start_date is null
   or df.forecast_start_date > df.coverage_end_date
