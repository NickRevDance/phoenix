{{ config(materialized = 'view') }}

-- Company-owned inventory only (join to ref_inventory_status on
-- include_in_std_metrics_flag = TRUE); partner-owned stock is served by
-- v_partner_inventory. Latest snapshot_date per the certified default scope
-- rule (spec v2.1 Section 5).

with latest_snapshot as (

    select max(snapshot_date) as max_snapshot_date
    from {{ ref('fact_inventory_snapshot_daily') }}

),

snapshot_current as (

    select f.*
    from {{ ref("fact_inventory_snapshot_daily") }} f
    inner join latest_snapshot ls
        on f.snapshot_date = ls.max_snapshot_date

),

status_scope as (

    select
          inventory_status_code
        , ownership_type
        , availability_class
        , program_name
        , partner_customer_id
    from {{ ref('ref_inventory_status') }}
    where is_current_row = 1
      and include_in_std_metrics_flag

),

product_current as (

    select
          product_key
        , style_name
        , summary_class
        , colorway          as color
        , size
        , original_season   as season
        , gender
    from {{ ref('dim_product') }}
    where is_current_row = 1

),

warehouse_current as (

    select
          warehouse_key
        , warehouse_name
        , warehouse_type
    from {{ ref('dim_warehouse') }}
    where is_current_row = true

),

final as (

    select

    -- Core ID
          s.inventory_snapshot_key
        , s.snapshot_date_key
        , s.snapshot_date
        , s.product_key
        , s.product_id
        , s.upc
        , s.sku
        , s.warehouse_key
        , s.warehouse_id
        , s.inventory_status_code
        , st.ownership_type
        , st.availability_class
        , st.program_name
        , st.partner_customer_id

    -- Quantities
        , s.on_hand_qty
        , s.available_qty
        , s.reserved_qty
        , s.allocated_qty
        , s.damaged_qty
        , s.hold_qty
        , s.in_transit_inbound_qty
        , s.in_transit_transfer_qty
        , s.on_order_qty
        , s.reorder_point_qty
        , s.safety_stock_qty
        , s.backorder_qty
        , s.qty_uom

    -- Costs
        , s.standard_cost_unit
        , s.standard_cost_amount
        , s.landed_cost_unit
        , s.landed_cost_amount
        , s.cost_variance_amount
        , s.retail_value_amount
        , s.available_cost_amount
        , s.damaged_cost_amount
        , s.cost_currency_code

    -- Status
        , s.lifecycle_status_code
        , s.availability_status_primary
        , s.inventory_site_id

    -- Aging
        , s.first_receipt_date
        , s.last_receipt_date
        , s.days_on_hand_age
        , s.age_bucket
        , s.last_sale_date

    -- Product attributes
        , p.style_name
        , p.summary_class
        , p.color
        , p.size
        , p.season
        , p.gender

    -- Warehouse attributes
        , w.warehouse_name
        , w.warehouse_type

    from snapshot_current s
    inner join status_scope st
        on s.inventory_status_code = st.inventory_status_code
    left join product_current p
        on s.product_key = p.product_key
    left join warehouse_current w
        on s.warehouse_key = w.warehouse_key

)

select * from final
