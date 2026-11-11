{{ config(materialized = 'view') }}

-- One row per forecast version + fiscal month + summary class + sales channel, budget beside
-- V_METRICS_SALES_DAILY actuals in USD. A total-company budget (channel_grain Total) compares to
-- actuals summed over every channel on sales_channel_key 0. Actual-only summary classes are kept so
-- actuals tie to the sales view. Actuals are NULL for months that have not started and 0 where a
-- started month has no sales.

with version_scope as (

    select

          df.forecast_version_key
        , df.forecast_version_id
        , df.forecast_display_name
        , df.forecast_type
        , df.forecast_cycle
        , df.forecast_status
        , df.is_primary_version
        , df.coverage_start_date
        , df.coverage_end_date
        , coalesce(df.channel_grain, 'Total') as channel_grain

    from {{ ref('dim_forecast') }} df
    where exists (
        select 1 from {{ ref('fact_budget_sales') }} f where f.forecast_version_key = df.forecast_version_key
    )

),

budget as (

    select

          f.forecast_version_key
        , f.budget_month_date
        , f.summary_class
        , f.sales_channel_key
        , max(f.product_group) as product_group
        , max(f.is_forecast_portion) as is_forecast_portion
        , {{ amount('sum(f.budget_net_sales)') }} as budget_net_sales
        , {{ amount('sum(f.budget_gross_margin)') }} as budget_gross_margin
        , {{ amount('sum(f.budget_units)') }} as budget_units

    from {{ ref('fact_budget_sales') }} f
    group by
          f.forecast_version_key
        , f.budget_month_date
        , f.summary_class
        , f.sales_channel_key

),

actual_channel as (

    select

          date_trunc('MONTH', s.invoice_date) as month_date
        , coalesce(s.summary_class, 'Unknown') as summary_class
        , s.sales_channel_key
        , max(s.product_group) as product_group
        , sum(s.net_sales_amount_usd) as actual_net_sales
        , sum(s.net_sales_amount_usd_with_moving_avg_cost) as actual_net_sales_with_cost
        , sum(s.gross_margin_moving_avg_amount_usd) as actual_gross_margin
        , sum(case when s.invoice_type = 'Sales Order' then s.invoiced_qty end) as actual_units

    from {{ ref('v_metrics_sales_daily') }} s
    group by
          date_trunc('MONTH', s.invoice_date)
        , coalesce(s.summary_class, 'Unknown')
        , s.sales_channel_key

),

actual as (

    select
          cast(a.month_date as date) as month_date
        , a.summary_class
        , a.sales_channel_key
        , a.product_group
        , a.actual_net_sales
        , a.actual_net_sales_with_cost
        , a.actual_gross_margin
        , a.actual_units
        , 'Channel' as actual_grain
    from actual_channel a

    union all

    select
          cast(a.month_date as date) as month_date
        , a.summary_class
        , cast(0 as bigint) as sales_channel_key
        , max(a.product_group) as product_group
        , sum(a.actual_net_sales) as actual_net_sales
        , sum(a.actual_net_sales_with_cost) as actual_net_sales_with_cost
        , sum(a.actual_gross_margin) as actual_gross_margin
        , sum(a.actual_units) as actual_units
        , 'Total' as actual_grain
    from actual_channel a
    group by cast(a.month_date as date), a.summary_class

),

actual_in_scope as (

    select

          v.forecast_version_key
        , a.month_date
        , a.summary_class
        , a.sales_channel_key
        , a.product_group
        , a.actual_net_sales
        , a.actual_net_sales_with_cost
        , a.actual_gross_margin
        , a.actual_units

    from version_scope v
    inner join actual a
        on a.month_date between v.coverage_start_date and v.coverage_end_date
       and a.actual_grain = case when v.channel_grain = 'Total' then 'Total' else 'Channel' end

),

combined as (

    select

          coalesce(b.forecast_version_key, a.forecast_version_key) as forecast_version_key
        , coalesce(b.budget_month_date, a.month_date) as budget_month_date
        , coalesce(b.summary_class, a.summary_class) as summary_class
        , coalesce(b.sales_channel_key, a.sales_channel_key) as sales_channel_key
        , coalesce(b.product_group, a.product_group) as product_group
        , coalesce(b.is_forecast_portion, 1) as is_forecast_portion
        , b.budget_net_sales
        , b.budget_gross_margin
        , b.budget_units
        , a.actual_net_sales
        , a.actual_net_sales_with_cost
        , a.actual_gross_margin
        , a.actual_units

    from budget b
    full outer join actual_in_scope a
        on a.forecast_version_key = b.forecast_version_key
       and a.month_date = b.budget_month_date
       and a.summary_class = b.summary_class
       and a.sales_channel_key = b.sales_channel_key

),

final as (

    select

          c.forecast_version_key
        , v.forecast_version_id
        , v.forecast_display_name
        , v.forecast_type
        , v.forecast_cycle
        , v.forecast_status
        , v.is_primary_version
        , d.date_key as budget_date_key
        , c.budget_month_date
        , d.fiscal_year
        , d.fiscal_quarter
        , d.fiscal_month
        , d.fiscal_month_name
        , d.fiscal_year_month_label
        , c.product_group
        , c.summary_class
        , r.reporting_category_group
        , r.reporting_subcategory
        , c.sales_channel_key
        , case when c.sales_channel_key = 0 then 'All Channels' else ch.channel_name end as channel_name
        , c.is_forecast_portion
        , case when c.budget_month_date <= current_date() then 1 else 0 end as is_actual_month
        , case when last_day(c.budget_month_date) < current_date() then 1 else 0 end as is_month_complete

        , {{ amount('coalesce(c.budget_net_sales, 0)') }} as budget_net_sales
        , {{ amount('case when c.budget_month_date <= current_date() then coalesce(c.actual_net_sales, 0) end') }} as actual_net_sales
        , {{ amount('case when c.budget_month_date <= current_date() then coalesce(c.actual_net_sales, 0) - coalesce(c.budget_net_sales, 0) end') }} as net_sales_variance
        , cast(case when c.budget_month_date <= current_date()
               then try_divide(coalesce(c.actual_net_sales, 0) - c.budget_net_sales, c.budget_net_sales) end as decimal(18,6)) as net_sales_variance_pct

        , c.budget_gross_margin
        , {{ amount('case when c.budget_month_date <= current_date() then coalesce(c.actual_gross_margin, 0) end') }} as actual_gross_margin
        , {{ amount('case when c.budget_month_date <= current_date() then coalesce(c.actual_net_sales_with_cost, 0) end') }} as actual_net_sales_with_cost
        , {{ amount('case when c.budget_month_date <= current_date() then coalesce(c.actual_gross_margin, 0) - c.budget_gross_margin end') }} as margin_variance

        , {{ amount('coalesce(c.budget_units, 0)') }} as budget_units
        , {{ amount('case when c.budget_month_date <= current_date() then coalesce(c.actual_units, 0) end') }} as actual_units
        , {{ amount('case when c.budget_month_date <= current_date() then coalesce(c.actual_units, 0) - coalesce(c.budget_units, 0) end') }} as units_variance

    from combined c
    inner join version_scope v
        on v.forecast_version_key = c.forecast_version_key
    inner join {{ ref('dim_date') }} d
        on d.date = c.budget_month_date
    left join {{ ref('dim_sales_channel') }} ch
        on ch.sales_channel_key = c.sales_channel_key
    left join {{ ref('ref_summary_class_rollup') }} r
        on r.summary_class = c.summary_class

)

select * from final
