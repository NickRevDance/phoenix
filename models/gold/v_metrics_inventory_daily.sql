{{ config(materialized = 'view') }}

{% set demand_window_days = var('inventory_demand_window_days', 90) %}

-- V_METRICS_INVENTORY_DAILY (spec v2.7, Section 5.2). Company-owned scope, daily grain, one row
-- per snapshot status row. Item + warehouse metrics (supply, demand, flags) repeat on every
-- status row of the same barcode + warehouse; never sum them across status rows.
-- Seam: backfill rows (legacy KPI population, available_qty NULL, historical cost) vs native
-- rows are told apart by record_source_table; a trend across 2026-09-01 steps as an artefact.
-- Demand: trailing {{ demand_window_days }} days before snapshot_date, FACT_SALES_INVOICE net of returns, all channels,
-- attributed on product_key + warehouse_key (same join as last_sale_date). NULL when the
-- snapshot row has no resolved product_key or warehouse_key.
-- NEEDS CONFIRMATION: excess_inventory_flag = 1 for stock with no demand in the window
-- (days_of_supply is undefined there), which goes beyond the literal "days_of_supply > 180".
-- NEEDS CONFIRMATION: the MADE_TO_ORDER exclusion (v2.7) is not applied; DIM_PRODUCT has no
-- stocking_policy yet (EDW-144).

with status_scope as (

    select st.inventory_status_code
    from {{ ref('ref_inventory_status') }} st
    where st.is_current_row = 1
      and st.include_in_std_metrics_flag

),

snapshot_scoped as (

    select
          f.*
        , coalesce(cast(f.product_key as string), f.upc) as variant_key
    from {{ ref('fact_inventory_snapshot_daily') }} f
    inner join status_scope st
        on f.inventory_status_code = st.inventory_status_code

),

item_warehouse as (

    -- spec 2.6: supply and coverage columns are item + warehouse grain, so every comparison
    -- runs on these aggregates, never on the status-grain row
    select
          s.snapshot_date
        , s.variant_key
        , s.warehouse_key
        , max(s.product_key)            as product_key
        , sum(s.available_qty)          as available_qty_iw
        , sum(s.on_hand_qty)            as on_hand_qty_iw
        , sum(s.standard_cost_amount)   as inventory_cost_iw
        , max(s.safety_stock_qty)       as safety_stock_qty_iw
    from snapshot_scoped s
    group by 1, 2, 3

),

demand_points as (

    select
          iw.product_key
        , iw.warehouse_key
        , datediff(iw.snapshot_date, date'1970-01-01') as day_num
        , cast(null as decimal(18,4))   as units_sold
        , cast(null as decimal(19,4))   as cogs_amount
        , cast(iw.inventory_cost_iw as decimal(19,4)) as inventory_cost
        , 1                             as is_snapshot_point
    from item_warehouse iw
    where iw.product_key is not null
      and cast(iw.product_key as string) <> '-1'
      and iw.warehouse_key is not null

),

demand_events as (

    select
          si.product_key
        , si.warehouse_key
        , datediff(si.invoice_date, date'1970-01-01') as day_num
        , cast(si.invoiced_qty as decimal(18,4))         as units_sold
        , cast(si.standard_cost_amount as decimal(19,4)) as cogs_amount
        , cast(null as decimal(19,4))   as inventory_cost
        , 0                             as is_snapshot_point
    from {{ ref('fact_sales_invoice') }} si
    where si.product_key is not null
      and cast(si.product_key as string) <> '-1'
      and si.warehouse_key is not null
      and si.invoice_date >= date_sub((select min(iw.snapshot_date) from item_warehouse iw), {{ demand_window_days }})

),

demand_windowed as (

    -- one ordered pass over snapshot points and invoice lines per product + warehouse;
    -- the demand frame excludes the snapshot day itself (the snapshot is taken overnight)
    select
          u.product_key
        , u.warehouse_key
        , u.day_num
        , u.is_snapshot_point
        , sum(u.units_sold) over (
            partition by u.product_key, u.warehouse_key
            order by u.day_num
            range between {{ demand_window_days }} preceding and 1 preceding
          ) as units_sold_window
        , sum(u.cogs_amount) over (
            partition by u.product_key, u.warehouse_key
            order by u.day_num
            range between {{ demand_window_days }} preceding and 1 preceding
          ) as cogs_window
        , avg(u.inventory_cost) over (
            partition by u.product_key, u.warehouse_key
            order by u.day_num
            range between {{ demand_window_days - 1 }} preceding and current row
          ) as avg_inventory_cost_window
    from (
        select * from demand_points
        union all
        select * from demand_events
    ) u

),

demand_calc as (

    select
          w.product_key
        , w.warehouse_key
        , w.day_num
        , greatest(coalesce(w.units_sold_window, 0), 0) as units_sold_window
        , greatest(coalesce(w.cogs_window, 0), 0)       as cogs_window
        , w.avg_inventory_cost_window
    from demand_windowed w
    where w.is_snapshot_point = 1

),

metrics_base as (

    select
          s.*
        , iw.available_qty_iw
        , iw.on_hand_qty_iw
        , iw.safety_stock_qty_iw
        , dc.units_sold_window
        , dc.cogs_window
        , dc.avg_inventory_cost_window
        , case when dc.units_sold_window is not null
               then dc.units_sold_window / {{ demand_window_days }} end as avg_daily_demand
    from snapshot_scoped s
    inner join item_warehouse iw
        on s.snapshot_date = iw.snapshot_date
        and s.variant_key <=> iw.variant_key
        and s.warehouse_key <=> iw.warehouse_key
    left join demand_calc dc
        on iw.product_key = dc.product_key
        and iw.warehouse_key = dc.warehouse_key
        and datediff(s.snapshot_date, date'1970-01-01') = dc.day_num

),

final as (

    select

    -- Core ID
          m.inventory_snapshot_key
        , m.snapshot_date_key
        , m.snapshot_date
        , m.product_key
        , m.product_id
        , m.warehouse_key
        , m.warehouse_id
        , m.inventory_status_code
        , m.record_source_table  -- seam label (spec 2.5 rule 3); native vs backfill population

    -- Inputs
        , m.on_hand_qty
        , m.available_qty
        , m.on_order_qty
        , m.in_transit_inbound_qty
        , m.in_transit_transfer_qty
        , m.safety_stock_qty
        , m.reorder_point_qty
        , m.last_sale_date
        , m.units_sold_window  as trailing_units_sold
        , cast({{ demand_window_days }} as int) as demand_window_days

    -- Certified metrics
        , case
            when m.avg_daily_demand > 0 and m.available_qty_iw is not null
                then cast(greatest(m.available_qty_iw, 0) / m.avg_daily_demand as decimal(18,4))
          end as days_of_supply  -- NULL = no demand in the window or not computable
        , case
            when m.avg_daily_demand > 0 and m.available_qty_iw is not null
                then cast(greatest(m.available_qty_iw, 0) / (m.avg_daily_demand * 7) as decimal(18,4))
          end as weeks_of_cover
        , case
            when m.cogs_window is not null and m.avg_inventory_cost_window > 0
                then cast((m.cogs_window * 365.0 / {{ demand_window_days }}) / m.avg_inventory_cost_window as decimal(18,4))
          end as inventory_turnover  -- annualized trailing COGS (standard cost) / average on-hand standard cost over the window
        , case
            when m.units_sold_window is null or m.available_qty_iw is null then cast(null as int)
            when m.available_qty_iw <= 0 and m.units_sold_window > 0 then 1
            else 0
          end as stockout_flag  -- only rows present in the snapshot can flag; all-zero positions are not rows (spec 2.3)
        , case
            when m.safety_stock_qty_iw is null then cast(null as int)
            when m.available_qty_iw < m.safety_stock_qty_iw then 1
            else 0
          end as below_safety_stock_flag  -- NULL = not computed (spec 2.4); compares item + warehouse available_qty (spec 2.6)
        , case when m.safety_stock_qty_iw is not null then 1 else 0 end as has_safety_stock_flag  -- scopes the alert to covered items (I2b)
        , case
            when m.units_sold_window is null or m.available_qty_iw is null then cast(null as int)
            when m.available_qty_iw <= 0 then 0
            when m.avg_daily_demand = 0 then 1
            when m.available_qty_iw / m.avg_daily_demand > 180 then 1
            else 0
          end as excess_inventory_flag
        , case
            when m.units_sold_window > 0
                then cast(m.on_hand_qty_iw / m.units_sold_window as decimal(18,4))
          end as stock_to_sales_ratio
        , datediff(m.snapshot_date, m.last_sale_date) as days_since_last_sale  -- NULL when never sold from this warehouse (spec 5.2)

    from metrics_base m

)

select * from final
