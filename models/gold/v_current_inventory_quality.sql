{{ config(materialized = 'view') }}

with latest_snapshot as (

    select
          max(q.snapshot_date) as snapshot_date

    from {{ ref('fact_inventory_quality_code_color_daily') }} q

),

product_hierarchy as (

    select
          p.code_color
        , max(p.style_name) as style_name
        , max(p.summary_class) as summary_class
        , max(p.reporting_category_group) as reporting_category_group
        , max(p.reporting_subcategory) as reporting_subcategory
        , max(p.division_season) as season
        , max(p.original_season) as original_season
        , max(p.gender) as gender
        , max(p.adult_child) as adult_child
        , max(p.brand) as brand

    from {{ ref('dim_product') }} p
    where p.is_current_row = 1
      and p.code_color is not null
    group by p.code_color

),

final as (

    select
          q.inventory_quality_key
        , q.snapshot_date_key
        , q.snapshot_date
        , q.code_color
        , q.warehouse_key
        , case when q.warehouse_key is null then 1 else 0 end as is_all_warehouse_row
        , q.source_system

        , q.style_number
        , ph.style_name
        , q.product_group
        , q.product_subgroup
        , ph.summary_class
        , ph.reporting_category_group
        , ph.reporting_subcategory
        , ph.season
        , ph.original_season
        , ph.gender
        , ph.adult_child
        , ph.brand

        , q.season_phase
        , q.is_month_start_snapshot
        , q.is_month_end_snapshot

        , q.total_on_hand_qty
        , q.total_available_qty
        , q.total_on_hand_cost
        , q.total_retail_value

        , q.size_count_total
        , q.size_count_in_stock
        , q.unmatched_size_count
        , q.core_size_count_total
        , q.core_size_count_in_stock
        , q.core_size_completeness_pct
        , q.broken_size_run_flag

        , q.size_weight_total
        , q.size_weight_in_stock
        , q.inventory_quality_score
        , q.inventory_quality_status
        , q.quality_band
        , q.avg_days_on_hand
        , q.aged_inventory_pct

        , q.sell_through_rate_30d
        , q.sell_through_rate_90d
        , q.units_sold_30d

        , q.etl_update_datetime

    from {{ ref('fact_inventory_quality_code_color_daily') }} q
    join latest_snapshot ls
        on q.snapshot_date = ls.snapshot_date
    left join product_hierarchy ph
        on q.code_color = ph.code_color

)

select * from final
