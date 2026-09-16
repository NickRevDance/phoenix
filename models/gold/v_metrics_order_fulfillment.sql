{{ config(materialized = 'view') }}

-- Certified fulfillment/return metrics view per spec Section 9. fill_rate
-- and on_time_ship_flag/pct are NOT computed here -- both need shipped_qty
-- / actual_ship_date, neither of which has a source yet (see
-- fact_orders_returns.sql). cancellation_rate, return_rate, and
-- demand_value_lost are computed since their inputs exist.

with base as (

    select * from {{ ref('fact_orders_returns') }}

),

product as (

    select

          product_key
        , style_name
        , summary_class
        , color_family
        , size
        , division_season
        , gender

    from {{ ref('dim_product') }}
    where version_number = 1

),

customer as (

    select

          customer_key
        , customer_name
        , customer_type
        , geo_state_province

    from {{ ref('dim_customer') }}
    where version_number = 1

),

channel as (

    select

          sales_channel_key
        , channel_name
        , channel_type

    from {{ ref('dim_sales_channel') }}

),

warehouse as (

    select

          warehouse_key
        , warehouse_name
        , warehouse_type

    from {{ ref('dim_warehouse') }}
    where is_current_row = true

),

date_dim as (

    select

          date_key
        , fiscal_year
        , fiscal_quarter
        , fiscal_month

    from {{ ref('dim_date') }}

)

select

      b.orders_returns_key
    , b.order_id
    , b.order_line_number
    , b.source_system
    , b.order_date
    , b.order_line_status
    , b.is_return_flag
    , b.is_cancelled_flag
    , b.is_backordered_flag

    , b.ordered_qty
    , b.cancelled_qty
    , b.returned_qty
    , b.unit_price
    , b.line_amount
    , b.net_line_amount
    , b.return_amount

    -- cancellation_rate: line-level, per spec formula (aggregate in BI)
    , case when b.ordered_qty <> 0 then b.cancelled_qty / b.ordered_qty end as cancellation_rate

    -- return_rate: returned_qty / shipped_qty per spec -- shipped_qty has no
    -- source, so this is null for every row until that gap is filled.
    , cast(null as decimal(9,6)) as return_rate  -- Source once available: needs shipped_qty

    , case when b.is_cancelled_flag then b.cancelled_qty * b.unit_price end as demand_value_lost

    , cast(null as decimal(9,4)) as fill_rate  -- Source once available: needs shipped_qty
    , cast(null as int) as order_to_ship_days  -- Source once available: needs actual_ship_date
    , cast(null as boolean) as on_time_ship_flag  -- Source once available: needs actual_ship_date

    , b.return_reason_code
    , b.return_reason_category
    , b.customer_purchase_order
    , b.rma_id
    , b.original_order_id
    , b.bigcommerce_order_id

    , pr.style_name
    , pr.summary_class
    , pr.color_family
    , pr.size
    , pr.division_season
    , pr.gender

    , cu.customer_name
    , cu.customer_type
    , cu.geo_state_province

    , ch.channel_name
    , ch.channel_type

    , wh.warehouse_name
    , wh.warehouse_type

    , d.fiscal_year
    , d.fiscal_quarter
    , d.fiscal_month

from base b

left join product pr
    on b.product_key = pr.product_key

left join customer cu
    on b.customer_key = cu.customer_key

left join channel ch
    on b.sales_channel_key = ch.sales_channel_key

left join warehouse wh
    on b.warehouse_key = wh.warehouse_key

left join date_dim d
    on b.order_date_key = d.date_key
