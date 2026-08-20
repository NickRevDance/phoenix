{{ config(materialized = 'view') }}

-- Latest position for partner-owned stock, by partner program (spec v2.1
-- Section 5.4, new in v2.1). Deliberately the inverse scope of the other
-- three views -- ownership_type = 'PARTNER_OWNED' instead of
-- include_in_std_metrics_flag = 1. Thin by design: no derived supply
-- metrics, partner stock has no demand-planning role.

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

partner_status as (

    select
          inventory_status_code
        , program_name
        , partner_customer_id
    from {{ ref('ref_inventory_status') }}
    where is_current_row = 1
      and ownership_type = 'PARTNER_OWNED'

),

product_current as (

    select
          product_key
        , style_name
        , colorway  as color
        , size
    from {{ ref('dim_product') }}
    where is_current_row = 1

),

warehouse_current as (

    select
          warehouse_key
        , warehouse_name
    from {{ ref('dim_warehouse') }}
    where is_current_row = true

),

final as (

    select

          s.inventory_status_code
        , ps.program_name
        , ps.partner_customer_id

        , s.product_id
        , s.sku
        , s.upc
        , p.style_name
        , p.color
        , p.size

        , s.warehouse_id
        , w.warehouse_name

        , s.on_hand_qty
        , s.available_qty
        , s.reserved_qty
        , s.snapshot_date

    from snapshot_current s
    inner join partner_status ps
        on s.inventory_status_code = ps.inventory_status_code
    left join product_current p
        on s.product_key = p.product_key
    left join warehouse_current w
        on s.warehouse_key = w.warehouse_key

)

select * from final
