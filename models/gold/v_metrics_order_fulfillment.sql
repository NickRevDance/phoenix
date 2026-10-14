{{ config(materialized = 'view') }}

-- Certified fulfillment/return metrics view per spec Section 9.
-- EDW-58 adds the return lifecycle columns, exchange_rate and
-- return_processing_days (spec Section 8).
-- EDW-57 fills the fulfillment metrics on the invoice basis (fulfillment_basis
-- 'INVOICE'; 'PACKING_SLIP' once the packing slip lands, EDW-55): fill_rate,
-- order_to_ship_days, on_time_ship_flag / on_time_ship_pct against the original
-- estimated ship date, and return_rate on shipped_qty. It also adds the open order
-- columns the Executive Summary reads, with the model's Open Order Status labels.
-- The open order columns read today's date in US Central at query time, so they
-- move from day to day without a rebuild.

with base as (

    select * from {{ ref('fact_orders_returns') }}

),

-- EDW-57: returned quantity against each original sales line, through the line link
-- (spec Section 3). Cancelled returns never arrived and are left out.
linked_return as (

    select

          original_d365_sales_line_rec_id
        , sum(returned_qty) as linked_returned_qty

    from {{ ref('fact_orders_returns') }}
    where is_return_flag
      and original_d365_sales_line_rec_id is not null
      and coalesce(return_status, '') <> 'Cancelled'
    group by original_d365_sales_line_rec_id

),

today as (

    select cast(from_utc_timestamp(current_timestamp(), 'America/Chicago') as date) as today_date

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
    where cast(is_current_row as int) = 1  -- works on boolean today and int after the EDW-90 rebuild

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
    , b.return_status
    , b.is_return_flag
    , b.is_cancelled_flag
    , b.is_backordered_flag
    , b.is_exchange_flag
    , b.is_replacement_flag

    , b.ordered_qty
    , b.cancelled_qty
    , b.returned_qty
    , b.unit_price
    , b.line_amount
    , b.net_line_amount
    , b.return_amount

    -- cancellation_rate: line-level, per spec formula (aggregate in BI)
    , case when b.ordered_qty <> 0 then b.cancelled_qty / b.ordered_qty end as cancellation_rate

    -- return_rate (EDW-57): on a sales row, the quantity returned against this line
    -- (linked return lines, not cancelled) over shipped_qty, per spec Section 8.
    -- NULL on return rows and on lines with nothing shipped.
    , case when not b.is_return_flag and b.shipped_qty > 0
           then cast(coalesce(lr.linked_returned_qty, 0) / b.shipped_qty as decimal(9,6)) end as return_rate

    , case when b.is_cancelled_flag then b.cancelled_qty * b.unit_price end as demand_value_lost

    -- Fulfillment (EDW-57), invoice basis
    , 'INVOICE' as fulfillment_basis
    , case when not b.is_return_flag and b.ordered_qty > 0
           then cast(b.shipped_qty / b.ordered_qty as decimal(9,4)) end as fill_rate  -- line-level; aggregate as sum(shipped_qty) / sum(ordered_qty)
    , case when not b.is_return_flag then datediff(b.actual_ship_date, b.order_date) end as order_to_ship_days
    , case when not b.is_return_flag and b.actual_ship_date is not null and b.original_estimated_ship_date is not null
           then b.actual_ship_date <= b.original_estimated_ship_date end as on_time_ship_flag  -- shipped on or before the first date promised
    , case when not b.is_return_flag and b.actual_ship_date is not null and b.original_estimated_ship_date is not null
           then cast(case when b.actual_ship_date <= b.original_estimated_ship_date then 1 else 0 end as decimal(9,6)) end as on_time_ship_pct  -- 1 or 0, so its average is the rate (the exchange_rate pattern)
    , b.shipped_qty
    , b.open_qty
    , lr.linked_returned_qty
    , b.is_partial_ship_flag
    , b.actual_ship_date
    , b.estimated_ship_date
    , b.original_estimated_ship_date
    , b.estimated_ship_date_status
    , b.carrier_code
    , b.payment_terms_code
    , b.payment_mode_code

    -- Open orders (EDW-57): a sales line with quantity still to ship and an order header.
    -- Lines whose order was deleted in D365 stay in silver with no header and are left out.
    -- Labels are the Executive Summary's Open Order Status.
    , case when not b.is_return_flag and b.open_qty > 0 and b.order_date is not null then true else false end as is_open_order_flag
    , case when not b.is_return_flag and b.open_qty > 0 and b.order_date is not null then
        case
            when b.estimated_ship_date_status = 'Not Assigned' then 'Awaiting Ship Date'
            when b.estimated_ship_date_status = 'Awaiting Release' then 'Branded - Awaiting Release'
            when b.estimated_ship_date < t.today_date then 'Past Due'
            when b.original_estimated_ship_date is not null and b.estimated_ship_date <> b.original_estimated_ship_date then 'Rescheduled'
            else 'On Schedule'
        end
      end as open_order_status
    , case when not b.is_return_flag and b.open_qty > 0 and b.order_date is not null
                and b.estimated_ship_date < t.today_date
           then datediff(t.today_date, b.estimated_ship_date) end as open_order_days_past_due
    , case when not b.is_return_flag and b.open_qty > 0 and b.order_date is not null
           then datediff(t.today_date, b.order_date) end as open_order_age_days
    , b.open_line_amount_usd
    , b.open_wholesale_amount_usd

    -- exchange_rate (EDW-58): exchange return lines over return lines, per spec
    -- Section 8. Line-level 1 or 0 on return rows, so its average over return
    -- rows is the rate (aggregate in BI). NULL on sales rows.
    , case when b.is_return_flag then cast(case when b.is_exchange_flag then 1 else 0 end as decimal(9,6)) end as exchange_rate

    -- return_processing_days (EDW-58): request to receipt, return_date -
    -- return_request_date. NULL until the return has arrived.
    , case when b.is_return_flag then datediff(b.return_date, b.return_request_date) end as return_processing_days

    , b.return_request_date
    , b.return_date
    , b.return_reason_code
    , b.return_reason_category
    , b.return_disposition
    , b.refund_method
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

cross join today t

-- EDW-57: sales rows only; a return row never matches its own rec id here.
left join linked_return lr
    on not b.is_return_flag
    and b.d365_sales_line_rec_id = lr.original_d365_sales_line_rec_id

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