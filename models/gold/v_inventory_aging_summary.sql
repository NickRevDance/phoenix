{{ config(materialized = 'view') }}

-- V_INVENTORY_AGING_SUMMARY (Inventory Gold Layer spec v2.6, Section 5.3). Pre-bucketed
-- aging at product/warehouse level. Company-owned scope, same as v_current_inventory.
-- age_bucket is NULL on every row until fact_inventory_snapshot_daily's Aging field group
-- is sourced from FACT_INVENTORY_MOVEMENT receipts (first_receipt_date / last_receipt_date,
-- see fact_inventory_snapshot_daily.sql) -- ready to populate once that lands.
-- (EDW-117 item 8: header references corrected from the pre-rename fact_inventory_on_hand.)
-- SEAM AND COST BASIS (spec 2.5, EDW-117 item 7): fact_inventory_snapshot_daily has two
-- source branches with different populations, told apart by record_source_table (a
-- branch constant). Backfill rows (legacy f_KPI_InventoryValue) are the legacy KPI
-- population, weekly cadence through 2025 and daily from 2026, with the legacy report's
-- historical unit cost; native rows (D365 InventSum + InventDim) are all statuses and
-- warehouses, daily from 2026-09-01, costed at FACT_PRODUCT_COST current STANDARD cost
-- on product_id. This view reads the LATEST snapshot only, so it is always inside the
-- native window; the note is here so anyone who parameterizes the date knows the seam.

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

    select inventory_status_code
    from {{ ref('ref_inventory_status') }}
    where is_current_row = 1
      and include_in_std_metrics_flag

),

product_current as (

    select
          product_key
        , style_name
        , summary_class
        , colorway  as color
        , size
    from {{ ref('dim_product') }}
    where is_current_row = 1

),

warehouse_current as (

    select
          warehouse_key
        , warehouse_name
        , warehouse_type
    from {{ ref('dim_warehouse') }}
    where cast(is_current_row as int) = 1  -- works on boolean today and int after the EDW-90 rebuild

),

bucketed as (

    select

          s.product_key
        , s.warehouse_key
        , s.age_bucket
        , sum(s.on_hand_qty)          as bucket_qty
        , sum(s.standard_cost_amount) as bucket_cost_amount
        , sum(s.retail_value_amount)  as bucket_retail_value

    from snapshot_current s
    inner join status_scope st
        on s.inventory_status_code = st.inventory_status_code
    group by 1, 2, 3

),

final as (

    select

          b.product_key
        , b.warehouse_key
        , b.age_bucket
        , b.bucket_qty
        , b.bucket_cost_amount
        , b.bucket_retail_value
        , b.bucket_qty / nullif(sum(b.bucket_qty) over (partition by b.product_key, b.warehouse_key), 0)
            as bucket_pct_of_total_qty
        , b.bucket_cost_amount / nullif(sum(b.bucket_cost_amount) over (partition by b.product_key, b.warehouse_key), 0)
            as bucket_pct_of_total_cost

        , p.style_name
        , p.summary_class
        , p.color
        , p.size

        , w.warehouse_name
        , w.warehouse_type

    from bucketed b
    left join product_current p
        on b.product_key = p.product_key
    left join warehouse_current w
        on b.warehouse_key = w.warehouse_key

)

select * from final
