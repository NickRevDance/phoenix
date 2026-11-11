{{ config(
    materialized = 'incremental',
    incremental_strategy = 'append',
    on_schema_change = 'sync_all_columns',
    full_refresh = false
) }}

{% set legacy_source = 'dwhvisualnext.analytics.f_BudgetSalesWithSummaryClass' %}

-- Insert-only per forecast version: a version's rows load once and are never touched again. The
-- legacy source is reloaded in place, so a revised budget needs a new forecast_version seed row
-- (and the old one set to Superseded); full_refresh = false keeps a rebuild from losing old versions.

with legacy_version as (

    select

          df.forecast_version_key
        , df.forecast_version_id
        , df.source_system
        , df.fiscal_year
        , df.coverage_start_date
        , df.coverage_end_date
        , df.actuals_through_date
        , row_number() over (
            partition by df.fiscal_year
            order by df.version_number desc, df.published_datetime desc nulls last
          ) as version_rank

    from {{ ref('dim_forecast') }} df
    where df.record_source_table = '{{ legacy_source }}'
      and df.forecast_type = 'Annual Budget'
      and df.forecast_status = 'Published'

),

budget_day as (

    select

          v.forecast_version_key
        , v.forecast_version_id
        , v.source_system
        , v.actuals_through_date
        , d.fiscal_year
        , d.fiscal_month as fiscal_month_number
        , d.first_day_of_month as budget_month_date
        , b.SummaryClass as summary_class
        , b.Budget as budget_net_sales
        , b.BudgetQty as budget_units

    from {{ ref('silver_dwh_budget_sales_summary_class') }} b
    inner join {{ ref('dim_date') }} d
        on d.date = b.SaleDate
    inner join legacy_version v
        on v.fiscal_year = d.fiscal_year
       and v.version_rank = 1
       and b.SaleDate between v.coverage_start_date and v.coverage_end_date

    {% if is_incremental() %}
    where not exists (
        select 1 from {{ this }} t where t.forecast_version_key = v.forecast_version_key
    )
    {% endif %}

),

budget_month as (

    select

          bd.forecast_version_key
        , bd.forecast_version_id
        , bd.source_system
        , bd.actuals_through_date
        , bd.fiscal_year
        , bd.fiscal_month_number
        , bd.budget_month_date
        , bd.summary_class
        , {{ amount('sum(bd.budget_net_sales)') }} as budget_net_sales
        , {{ amount('sum(bd.budget_units)') }} as budget_units

    from budget_day bd
    group by
          bd.forecast_version_key
        , bd.forecast_version_id
        , bd.source_system
        , bd.actuals_through_date
        , bd.fiscal_year
        , bd.fiscal_month_number
        , bd.budget_month_date
        , bd.summary_class

),

summary_class_group as (

    select

          p.summary_class
        , max(p.product_group) as product_group

    from {{ ref('dim_product') }} p
    where p.version_number = 1
      and p.summary_class is not null
    group by p.summary_class
    having count(distinct p.product_group) = 1

),

final as (

    select

          {{ generate_surrogate_key([
              'bm.forecast_version_key'
            , 'md.date_key'
            , 'bm.summary_class'
            , 'cast(0 as bigint)'
            , 'bm.source_system'
          ]) }} as budget_sales_key
        , concat_ws('|', bm.forecast_version_id, date_format(bm.budget_month_date, 'yyyy-MM'), bm.summary_class, 'ALL_CHANNELS') as budget_line_id
        , bm.source_system
        , bm.forecast_version_key
        , md.date_key as budget_date_key
        , cast(null as string) as product_key  -- Source once available: SKU-level budget -- Phase 2 per spec
        , cast(null as bigint) as summary_class_key  -- Source once available: summary class dimension (DIM_PRODUCT_HIERARCHY) -- not built yet
        , scg.product_group
        , bm.summary_class
        , cast(0 as bigint) as sales_channel_key  -- budget is total company; 0 = DIM_SALES_CHANNEL Not Applicable
        , cast(null as bigint) as employee_sales_hierarchy_key  -- Source once available: DIM_EMPLOYEE_SALES_HIERARCHY -- Phase 2 per spec
        , cast(null as bigint) as customer_segment_key  -- Source once available: segment-level budget -- Phase 3 per spec
        , bm.budget_month_date
        , bm.fiscal_year
        , bm.fiscal_month_number
        , cast(null as decimal(38,6)) as budget_gross_sales  -- Source once available: Planful -- Phase 2 per spec
        , cast(null as decimal(38,6)) as budget_discount_amount  -- Source once available: Planful -- Phase 2 per spec
        , bm.budget_net_sales
        , cast(null as decimal(38,6)) as budget_standard_cost  -- Source once available: Planful -- legacy budget carries no cost
        , cast(null as decimal(38,6)) as budget_gross_margin  -- Source once available: Planful -- legacy budget carries no cost
        , cast(null as decimal(38,6)) as budget_landed_cost  -- Source once available: Planful -- Phase 2 per spec
        , bm.budget_units
        , cast(null as decimal(38,6)) as budget_asp  -- Source once available: derivable, Phase 2 per spec
        , cast(null as decimal(9,4)) as budget_gross_margin_pct  -- Source once available: derivable, Phase 2 per spec
        , cast(null as decimal(9,4)) as budget_discount_rate  -- Source once available: derivable, Phase 2 per spec
        , case
            when bm.actuals_through_date is null then 1
            when bm.budget_month_date > bm.actuals_through_date then 1
            else 0
          end as is_forecast_portion
        , '{{ legacy_source }}' as record_source_table
        , current_timestamp() as etl_insert_datetime
        , current_timestamp() as etl_update_datetime
        , {{ generate_row_hash([
              "coalesce(cast(bm.budget_net_sales as string), '')"
            , "coalesce(cast(bm.budget_units as string), '')"
          ]) }} as row_hash

    from budget_month bm
    inner join {{ ref('dim_date') }} md
        on md.date = bm.budget_month_date
    left join summary_class_group scg
        on scg.summary_class = bm.summary_class

)

select * from final
