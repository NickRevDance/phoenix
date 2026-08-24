{{ config(materialized = 'view') }}

-- Certified daily inventory metrics (spec v2.1 Section 5.2). Company-owned
-- scope, same as v_current_inventory. Phase 1 core metrics only -- the
-- demand-dependent metrics (days_of_supply, weeks_of_cover,
-- inventory_turnover, stockout_flag, excess_inventory_flag,
-- stock_to_sales_ratio) are null until a sales fact exists to source
-- rolling demand from (Phase 3 per spec).

with latest_snapshot as (

    select max(snapshot_date) as max_snapshot_date
    from {{ ref('fact_inventory_snapshot_daily') }}

),

snapshot_current as (

    select f.*
    from {{ ref('fact_inventory_snapshot_daily') }} f
    inner join latest_snapshot ls
        on f.snapshot_date = ls.max_snapshot_date

),

status_scope as (

    select inventory_status_code
    from {{ ref('ref_inventory_status') }}
    where is_current_row = 1
      and include_in_std_metrics_flag

),

final as (

    select

    -- Core ID
          s.inventory_snapshot_key
        , s.snapshot_date_key
        , s.snapshot_date
        , s.product_key
        , s.product_id
        , s.warehouse_key
        , s.warehouse_id
        , s.inventory_status_code

    -- Inputs
        , s.on_hand_qty
        , s.available_qty
        , s.safety_stock_qty
        , s.reorder_point_qty
        , s.last_sale_date

    -- Certified metrics
        , null  days_of_supply         -- Source once available: rolling_avg_daily_demand, requires an operational sales fact (Phase 3)
        , null  weeks_of_cover         -- Source once available: rolling_avg_weekly_demand, requires an operational sales fact (Phase 3)
        , null  inventory_turnover     -- Source once available: annualized_cogs + avg_inventory_cost, requires an operational sales fact (Phase 3)
        , null  stockout_flag          -- Source once available: requires trailing-period demand to confirm recent demand exists (Phase 3)
        , case when s.available_qty < s.safety_stock_qty then 1 else 0 end  as below_safety_stock_flag
        , case when s.available_qty < s.reorder_point_qty then 1 else 0 end as reorder_flag
        , null  excess_inventory_flag  -- Source once available: depends on days_of_supply above (Phase 3)
        , null  stock_to_sales_ratio   -- Source once available: trailing_period_units_sold, requires an operational sales fact (Phase 3)
        , datediff(day, s.last_sale_date, s.snapshot_date) as days_since_last_sale

    from snapshot_current s
    inner join status_scope st
        on s.inventory_status_code = st.inventory_status_code

)

select * from final
