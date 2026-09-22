{{ config(materialized = 'view') }}

-- V_METRICS_INVENTORY_DAILY (Inventory Gold Layer spec v2.6, Section 5.2). The primary
-- certified inventory metric view. Company-owned scope (REF_INVENTORY_STATUS
-- include_in_std_metrics_flag = 1), same as v_current_inventory.
--
-- DAILY GRAIN (EDW-117 item 6): every snapshot date, not the latest only. The series is
-- sparse where spec 2.7 records a gap (Sep 4-9 2026); the view does not fabricate rows.
--
-- SEAM AND CADENCE (spec 2.5, EDW-117 item 7): the fact has two source branches with
-- different populations, told apart by record_source_table (a branch constant):
--   * backfill rows (legacy f_KPI_InventoryValue): the legacy KPI population; weekly
--     cadence (Sundays plus month ends) through 2025, daily from 2026; status detail only
--     from mid-2026; standard_cost_unit is the legacy report's historical unit cost and
--     available_qty / reserved_qty are NULL.
--   * native rows (D365 InventSum + InventDim): all statuses, all warehouses, daily from
--     2026-09-01; cost is FACT_PRODUCT_COST current STANDARD cost, joined on product_id.
-- A trend crossing the seam steps as an artefact of population, not business movement;
-- per-day averages over the weekly-cadence window are wrong by about a factor of seven.
-- Consumers label the seam (record_source_table) and trend the backfill at its cadence.
--
-- Phase 1 core metrics only. Demand-dependent metrics are NULL until EDW-51 sources
-- rolling demand from the certified sales fact. below_safety_stock_flag / reorder_flag
-- return NULL (not computed) while safety_stock_qty / reorder_point_qty are NULL
-- (EDW-126); when they land, the comparison is against available_qty summed to item +
-- warehouse, because supply and coverage columns are item + warehouse grain on the
-- rank-1 status row (spec 2.6), never against the status-grain row alone.

with status_scope as (

    select inventory_status_code
    from {{ ref('ref_inventory_status') }}
    where is_current_row = 1
      and include_in_std_metrics_flag

),

snapshot_scoped as (

    select f.*
    from {{ ref('fact_inventory_snapshot_daily') }} f
    inner join status_scope st
        on f.inventory_status_code = st.inventory_status_code

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
        , s.record_source_table  -- seam label (spec 2.5 rule 3); native vs backfill population

    -- Inputs
        , s.on_hand_qty
        , s.available_qty
        , s.on_order_qty
        , s.in_transit_inbound_qty
        , s.in_transit_transfer_qty
        , s.safety_stock_qty
        , s.reorder_point_qty
        , s.last_sale_date

    -- Certified metrics
        , cast(null as decimal(18,4)) as days_of_supply         -- Source once available: rolling_avg_daily_demand from the certified sales fact (EDW-51)
        , cast(null as decimal(18,4)) as weeks_of_cover         -- Source once available: rolling_avg_weekly_demand (EDW-51)
        , cast(null as decimal(18,4)) as inventory_turnover     -- Source once available: annualized_cogs / avg_inventory_cost (EDW-51)
        , cast(null as int)           as stockout_flag          -- Source once available: needs trailing-period demand (EDW-51)
        , case
            when s.safety_stock_qty is null then cast(null as int)
            when sum(s.available_qty) over (partition by s.snapshot_date_key, s.product_id, s.warehouse_key) < s.safety_stock_qty then 1
            else 0
          end as below_safety_stock_flag  -- NULL = not computed (spec 2.4); item + warehouse aggregation per spec 2.6
        , case
            when s.reorder_point_qty is null then cast(null as int)
            when sum(s.available_qty) over (partition by s.snapshot_date_key, s.product_id, s.warehouse_key) < s.reorder_point_qty then 1
            else 0
          end as reorder_flag             -- NULL = not computed; descoped while reorder point is not maintained (EDW-126)
        , cast(null as int)           as excess_inventory_flag  -- Source once available: depends on days_of_supply (EDW-51)
        , cast(null as decimal(18,4)) as stock_to_sales_ratio   -- Source once available: trailing_period_units_sold (EDW-51)
        , datediff(s.snapshot_date, s.last_sale_date) as days_since_last_sale  -- NULL when never sold from this warehouse (spec 5.2)

    from snapshot_scoped s

)

select * from final
