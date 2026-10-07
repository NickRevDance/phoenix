{{ config(materialized = 'view') }}

{% set demand_window_days = var('inventory_demand_window_days', 90) %}
{% set excess_window_days = 365 %}    {# I4: fixed, the column trailing_units_sold_365 carries it in its name #}
{% set excess_new_item_days = 180 %}  {# I4: an item first sold fewer days ago than this is not assessed for excess #}

-- V_METRICS_INVENTORY_DAILY (spec v2.7, Section 5.2). Company-owned scope, daily grain, one row
-- per snapshot status row. Item + warehouse metrics (supply, demand, flags) repeat on every
-- status row of the same barcode + warehouse; never sum them across status rows.
-- Seam: backfill rows (legacy KPI population, available_qty NULL, historical cost) vs native
-- rows are told apart by record_source_table; a trend across 2026-09-01 steps as an artefact.
-- Demand: trailing {{ demand_window_days }} days before snapshot_date, FACT_SALES_INVOICE net of returns, all channels,
-- attributed on product_key + warehouse_key (same join as last_sale_date). NULL when the
-- snapshot row has no resolved product_key (the unknown member, '-1', EDW-151) or warehouse_key.
-- Excess (ruling I4, ratified 2026-10-07, EDW-172, Inventory Excess and Demand Basis Decision
-- Record v1.0; replaces the 180-day test on the {{ demand_window_days }}-day window confirmed 2026-10-01 on EDW-51):
-- excess_inventory_flag = 1 when item + warehouse available stock is above the net units sold
-- in the trailing {{ excess_window_days }} days before snapshot_date (more than one year of supply), or when
-- nothing sold in those {{ excess_window_days }} days. An item first sold fewer than {{ excess_new_item_days }} days before
-- snapshot_date, in any warehouse, is not assessed (0): it has no full season of sales to be
-- measured against. An item with no sale before snapshot_date flags as no sale, since there is
-- no receipt date to tell new stock from dead stock. excess_qty is the units above the
-- one-year line, spread over the pair's status rows in proportion to positive available_qty,
-- so unlike the other item + warehouse columns it CAN be summed. days_of_supply,
-- weeks_of_cover, stock_to_sales_ratio and inventory_turnover stay on the {{ demand_window_days }}-day window:
-- they are run-rate measures and are meant to move with the season.
-- Demand basis (ruling I5, ratified 2026-10-07, EDW-172, same record): demand stays net of
-- returns received in the window, floored at zero. Unchanged from the build.
-- Turnover: average on-hand standard cost uses snapshot points from the row's own branch only
-- (native rows average native days, backfill rows average backfill days), because the two
-- branches carry different cost bases; a point where stock has no cost is left out rather than
-- averaged in as zero. Early native days therefore average over fewer than {{ demand_window_days }} days.
-- Stocking policy (EDW-144, Merchandising decision M2): items marked MADE_TO_ORDER in
-- ref_stocking_policy carry a seeded placeholder quantity that is not stock, and are left out
-- on every date. The rule is keyed on product_id because the family is not in DIM_PRODUCT.
-- Backfill rows of such an item have no product_id, only the UPC, so those are matched on the
-- UPCs the item's native rows carry (every backfill UPC of the family has native rows).

with status_scope as (

    select st.inventory_status_code
    from {{ ref('ref_inventory_status') }} st
    where st.is_current_row = 1
      and st.include_in_std_metrics_flag

),

made_to_order as (

    select product_id
    from {{ ref('ref_stocking_policy') }}
    where stocking_policy = 'MADE_TO_ORDER'

),

made_to_order_upc as (

    select distinct f.upc
    from {{ ref('fact_inventory_snapshot_daily') }} f
    inner join made_to_order mto
        on f.product_id = mto.product_id
    where f.upc is not null

),

snapshot_scoped as (

    select
          f.*
        , case
            when f.product_key is null or cast(f.product_key as string) = '-1' then f.upc  -- EDW-151: unresolved variants share the unknown member, so the UPC tells them apart
            else cast(f.product_key as string)
          end as variant_key
    from {{ ref('fact_inventory_snapshot_daily') }} f
    inner join status_scope st
        on f.inventory_status_code = st.inventory_status_code
    -- EDW-144: stocked items only
    left anti join made_to_order mto
        on f.product_id = mto.product_id
    left anti join made_to_order_upc mtu
        on f.upc = mtu.upc

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
        , sum(greatest(s.available_qty, 0)) as available_pos_qty_iw  -- I4: allocation base for excess_qty
        , sum(s.on_hand_qty)            as on_hand_qty_iw
        , sum(s.standard_cost_amount)   as inventory_cost_iw
        , max(s.safety_stock_qty)       as safety_stock_qty_iw
        , max(case when s.record_source_table = {{ inventory_snapshot_branch_label('native') }} then 1 else 0 end) as is_native_branch  -- a snapshot date is one branch (seam 2026-09-01)
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
        , case
            when iw.on_hand_qty_iw <> 0 and coalesce(iw.inventory_cost_iw, 0) = 0
                then cast(null as decimal(19,4))  -- stock with no cost: the cost is missing, not zero
            else cast(iw.inventory_cost_iw as decimal(19,4))
          end                           as inventory_cost
        , 1                             as is_snapshot_point
        , iw.is_native_branch
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
        , cast(null as int)             as is_native_branch
    from {{ ref('fact_sales_invoice') }} si
    where si.product_key is not null
      and cast(si.product_key as string) <> '-1'
      and si.warehouse_key is not null
      and si.invoice_date >= date_sub((select min(iw.snapshot_date) from item_warehouse iw), {{ [demand_window_days, excess_window_days] | max }})

),

first_sale as (

    -- I4: first invoiced sale of the product in any warehouse, over all invoice history
    select
          si.product_key
        , min(si.invoice_date) as first_sale_date
    from {{ ref('fact_sales_invoice') }} si
    where si.product_key is not null
      and cast(si.product_key as string) <> '-1'
      and si.invoiced_qty > 0
    group by 1

),

demand_windowed as (

    -- one ordered pass over snapshot points and invoice lines per product + warehouse;
    -- the demand frame excludes the snapshot day itself (the snapshot is taken overnight)
    select
          u.product_key
        , u.warehouse_key
        , u.day_num
        , u.is_snapshot_point
        , u.is_native_branch
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
        , sum(u.units_sold) over (
            partition by u.product_key, u.warehouse_key
            order by u.day_num
            range between {{ excess_window_days }} preceding and 1 preceding
          ) as units_sold_excess_window  -- I4: same frame rule, one year
        -- one average per branch; the snapshot point picks its own branch in demand_calc
        , avg(case when u.is_native_branch = 1 then u.inventory_cost end) over (
            partition by u.product_key, u.warehouse_key
            order by u.day_num
            range between {{ demand_window_days - 1 }} preceding and current row
          ) as avg_inventory_cost_native
        , avg(case when u.is_native_branch = 0 then u.inventory_cost end) over (
            partition by u.product_key, u.warehouse_key
            order by u.day_num
            range between {{ demand_window_days - 1 }} preceding and current row
          ) as avg_inventory_cost_backfill
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
        , greatest(coalesce(w.units_sold_excess_window, 0), 0) as units_sold_excess_window  -- I5: net of returns, floored at zero
        , case
            when w.is_native_branch = 1 then w.avg_inventory_cost_native
            else w.avg_inventory_cost_backfill
          end as avg_inventory_cost_window
    from demand_windowed w
    where w.is_snapshot_point = 1

),

metrics_base as (

    select
          s.*
        , iw.available_qty_iw
        , iw.on_hand_qty_iw
        , iw.safety_stock_qty_iw
        , iw.available_pos_qty_iw
        , dc.units_sold_window
        , dc.cogs_window
        , dc.avg_inventory_cost_window
        , dc.units_sold_excess_window
        , fs.first_sale_date
    from snapshot_scoped s
    inner join item_warehouse iw
        on s.snapshot_date = iw.snapshot_date
        and s.variant_key <=> iw.variant_key
        and s.warehouse_key <=> iw.warehouse_key
    left join demand_calc dc
        on iw.product_key = dc.product_key
        and iw.warehouse_key = dc.warehouse_key
        and datediff(s.snapshot_date, date'1970-01-01') = dc.day_num
    left join first_sale fs
        on iw.product_key = fs.product_key

),

metrics_excess as (

    -- ruling I4 (2026-10-07): one year of supply on the trailing {{ excess_window_days }}-day net sales
    select
          b.*
        , case
            when b.units_sold_excess_window is null or b.available_qty_iw is null then cast(null as int)
            when b.available_qty_iw <= 0 then 0
            when b.first_sale_date < b.snapshot_date
                 and datediff(b.snapshot_date, b.first_sale_date) < {{ excess_new_item_days }} then 0  -- new item, not assessed
            when b.units_sold_excess_window = 0 then 1  -- no sale in the {{ excess_window_days }} days
            when b.available_qty_iw > b.units_sold_excess_window then 1  -- more than one year of supply
            else 0
          end as excess_inventory_flag
    from metrics_base b

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
        , m.units_sold_excess_window as trailing_units_sold_365  -- I4: net units in the {{ excess_window_days }} days before snapshot_date, the excess basis

    -- Certified metrics
        , case
            when m.units_sold_window > 0 and m.available_qty_iw is not null
                then cast(greatest(m.available_qty_iw, 0) * {{ demand_window_days }} / m.units_sold_window as decimal(18,4))
          end as days_of_supply  -- available / (units / window), multiplied through so no rounded daily rate; NULL = no demand in the window or not computable
        , case
            when m.units_sold_window > 0 and m.available_qty_iw is not null
                then cast(greatest(m.available_qty_iw, 0) * {{ demand_window_days }} / (m.units_sold_window * 7) as decimal(18,4))
          end as weeks_of_cover
        , case
            when m.cogs_window is not null and m.avg_inventory_cost_window > 0
                then cast((m.cogs_window * 365.0 / {{ demand_window_days }}) / m.avg_inventory_cost_window as decimal(18,4))
          end as inventory_turnover  -- annualized trailing COGS (standard cost) / average on-hand standard cost over the window, same-branch costed points only
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
        , m.excess_inventory_flag  -- ruling I4, see metrics_excess
        , case
            when m.excess_inventory_flag is null then cast(null as decimal(18,4))
            when m.excess_inventory_flag = 1 and m.available_pos_qty_iw > 0
                then cast((m.available_qty_iw - m.units_sold_excess_window) * greatest(m.available_qty, 0) / m.available_pos_qty_iw as decimal(18,4))
            else cast(0 as decimal(18,4))
          end as excess_qty  -- units above the one-year line, this row's share by positive available_qty; sums to the pair's excess
        , case
            when m.units_sold_window > 0
                then cast(m.on_hand_qty_iw / m.units_sold_window as decimal(18,4))
          end as stock_to_sales_ratio
        , datediff(m.snapshot_date, m.last_sale_date) as days_since_last_sale  -- NULL when never sold from this warehouse (spec 5.2)

    from metrics_excess m

)

select * from final