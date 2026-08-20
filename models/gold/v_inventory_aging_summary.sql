{{ config(materialized = 'view') }}

-- Pre-bucketed aging at product/warehouse level (spec v2.1 Section 5.3).
-- Company-owned scope, same as v_current_inventory. age_bucket is null for
-- every row until fact_inventory_on_hand's Aging field group is sourced
-- (see fact_inventory_on_hand.sql) -- ready to populate once that lands.

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
      and include_in_std_metrics_flag = 1

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
    where is_current_row = true

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
