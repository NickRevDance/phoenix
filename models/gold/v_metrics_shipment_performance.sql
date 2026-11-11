{{ config(materialized = 'view') }}

-- Certified shipment metrics at shipment-line grain (FACT_SHIPMENT spec 9). Delivery metrics stay NULL until the
-- carrier feed lands. Freight margin joins FACT_SALES_INVOICE.shipping_revenue on invoice_id + d365_sales_line_rec_id
-- once both shipping revenue and shipping cost have a source; both are NULL today.

with shipment as (

    select f.*
    from {{ ref('fact_shipment') }} f

),

service as (

    select

          r.carrier_code
        , r.carrier_service_code
        , r.is_carrier_metric_eligible

    from {{ ref('ref_shipping_service') }} r

),

final as (

    select

    -- Grain and keys
          s.shipment_key
        , s.shipment_id
        , s.shipment_line_number
        , s.order_id
        , s.order_line_number
        , s.invoice_id
        , s.packing_slip_id
        , s.ship_date_key
        , s.sla_delivery_date_key
        , s.actual_delivery_date_key
        , s.product_key
        , s.customer_key
        , s.sales_channel_key
        , s.warehouse_key
        , s.ship_date
        , s.sla_delivery_date
        , s.actual_delivery_date
        , s.shipment_status
        , s.is_delivered_flag
        , s.is_exception_flag
        , s.exception_reason
        , s.is_split_shipment_flag

    -- Measures (pass-through)
        , s.shipped_qty
        , s.shipping_cost_total
        , s.shipping_cost_allocated
        , s.package_count
        , s.total_weight_lbs
        , s.line_weight_lbs

    -- Certified metrics (spec 8)
        , datediff(s.actual_delivery_date, s.ship_date) as transit_days
        , case when s.actual_delivery_date is not null and s.sla_delivery_date is not null
               then s.actual_delivery_date <= s.sla_delivery_date end as on_time_delivery_flag
        , s.shipping_cost_allocated / nullif(s.shipped_qty, 0) as cost_per_unit_shipped
        , s.shipping_cost_total / nullif(s.package_count, 0) as cost_per_package
        , cast(null as decimal(19,4)) as shipping_revenue  -- Source once available: FACT_SALES_INVOICE.shipping_revenue (its Open Decision 3)
        , cast(null as decimal(19,4)) as freight_margin_amount  -- shipping_revenue - shipping_cost_allocated
        , cast(null as decimal(38,6)) as freight_margin_pct  -- freight_margin_amount / shipping_revenue, 0 when revenue is 0
        , coalesce(sv.is_carrier_metric_eligible, s.carrier_code not in ('SHIP_TO_DESK', 'UNKNOWN')) as is_carrier_metric_eligible  -- CS4: Ship to Desk is a delivery method, left out of carrier scorecards

    -- Carrier context
        , s.carrier_code
        , s.carrier_name
        , s.shipping_method
        , s.carrier_service_code
        , s.tracking_number

    -- Destination
        , s.ship_to_state_province
        , s.ship_to_country_code
        , s.shipping_zone

    -- Product
        , p.style_name
        , p.summary_class
        , p.colorway as color
        , p.size
        , p.original_season as season
        , p.gender

    -- Customer
        , c.customer_name
        , c.customer_type
        , c.geo_state_province

    -- Channel
        , ch.channel_name
        , ch.channel_type
        , ch.storefront_code  -- spec lists storefront_name; DIM_SALES_CHANNEL carries the code only

    -- Warehouse
        , w.warehouse_name
        , w.warehouse_type

    -- Date
        , d.fiscal_year
        , d.fiscal_quarter
        , d.fiscal_month
        , d.fiscal_year_week as fiscal_week

    from shipment s
    left join service sv
        on sv.carrier_code = s.carrier_code
       and coalesce(sv.carrier_service_code, '') = coalesce(s.carrier_service_code, '')
    left join {{ ref('v_dim_product_current') }} p
        on p.product_key = s.product_key
    left join {{ ref('v_dim_customer_current') }} c
        on c.customer_key = s.customer_key
    left join {{ ref('v_dim_sales_channel_current') }} ch
        on ch.sales_channel_key = s.sales_channel_key
    left join {{ ref('v_dim_warehouse_current') }} w
        on w.warehouse_key = s.warehouse_key
    left join {{ ref('dim_date') }} d
        on d.date_key = s.ship_date_key

)

select * from final
