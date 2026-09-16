{{ config(
    materialized = 'incremental',
    unique_key = 'orders_returns_key',
    incremental_strategy = 'merge',
    on_schema_change = 'sync_all_columns'
) }}

with line as (

    select

          l.REC
        , l.SALESID
        , l.LINENUM
        , l.ITEMID
        , l.INVENTDIMID
        , l.SALESTYPE
        , l.QTYORDERED
        , l.REVQTYCANCELLED
        , l.SALESPRICE
        , l.SALESUNIT
        , l.LINEDISC
        , l.CURRENCYCODE
        , l.SALESSTATUS
        , l.SHIPPINGDATEREQUESTED
        , l.RETURNARRIVALDATE
        , l.RETURNDISPOSITIONCODEID
        , l.MODIFIEDDATE

    from {{ ref('silver_d365_sales_line') }} l

    -- Both forward-demand (3) and return (4) lines belong in this fact --
    -- unlike FACT_ORDER_LINE, which filters to 3 only. See spec Section 4.9
    -- (combined orders-and-returns design) and README.
    where l.SALESTYPE in (3, 4)

    {% if is_incremental() %}
    and l.MODIFIEDDATE > (select coalesce(max(etl_source_modified_datetime), timestamp('1900-01-01')) from {{ this }}) - interval 2 days
    {% endif %}

),

sales_table as (

    select

          st.SALESID
        , st.REC
        , st.CUSTACCOUNT
        , st.SALESORIGINID
        , st.DLVMODE
        , st.PURCHORDERFORMNUM
        , st.CREATEDDATE

    from {{ ref('silver_d365_sales_table') }} st

),

-- New this build: D365's return-order extension table (McrReturnSalesTable),
-- one row per return sales order header, linked 1:1 to SalesTable via
-- SALESTABLE = SalesTable.REC (confirmed live: 138,758 rows in, 138,758
-- distinct SALESTABLE). Carries the return-to-original-order linkage.
return_header as (

    select

          r.SALESTABLE
        , r.ORIGINALSALESID
        , r.REC as return_header_rec

    from {{ ref('silver_d365_mcr_return_sales_table') }} r

),

inventory_dim as (

    select

          InventDimID
        , inventsiteid
        , INVENTLOCATIONID
        , INVENTSIZEID
        , INVENTCOLORID

    from {{ ref('silver_d365_inventory_dim') }}

),

product as (

    select

          product_key
        , style_number
        , size
        , d365_color_code

    from {{ ref('dim_product') }}
    where version_number = 1

),

customer as (

    select

          customer_key
        , customer_id

    from {{ ref('dim_customer') }}
    where version_number = 1
      and source_system = 'D365'

),

warehouse as (

    select

          warehouse_key
        , warehouse_id
        , d365_site_id

    from {{ ref('dim_warehouse') }}
    where is_current_row = true

),

sales_origin_map as (

    select

          sales_origin_id
        , channel_code

    from {{ ref('ref_sales_origin_map') }}
    where is_active_flag = 1

),

sales_channel as (

    select

          sales_channel_key
        , channel_code

    from {{ ref('dim_sales_channel') }}

),

{% if is_incremental() %}
-- Preserves etl_insert_datetime across merges -- Type 1 overwrite means a
-- line's row is updated in place on every status/quantity change, and the
-- spec's own field catalog distinguishes insert (fixed) from update
-- (touched every change). Without this, a plain incremental merge would
-- reset etl_insert_datetime on every touched row.
existing as (

    select

          orders_returns_key
        , etl_insert_datetime

    from {{ this }}

),
{% endif %}

joined as (

    select

          l.REC
        , l.SALESID
        , l.LINENUM
        , l.SALESTYPE
        , l.QTYORDERED
        , l.REVQTYCANCELLED
        , l.SALESPRICE
        , l.SALESUNIT
        , l.LINEDISC
        , l.CURRENCYCODE
        , l.SALESSTATUS
        , l.SHIPPINGDATEREQUESTED
        , l.RETURNARRIVALDATE
        , l.RETURNDISPOSITIONCODEID
        , l.MODIFIEDDATE

        , st.CUSTACCOUNT
        , st.SALESORIGINID
        , st.DLVMODE
        , st.PURCHORDERFORMNUM
        , st.CREATEDDATE                         as order_created_date

        , rh.ORIGINALSALESID
        , rh.return_header_rec

        , d.INVENTLOCATIONID
        , pr.product_key
        , cu.customer_key
        , wh.warehouse_key
        , coalesce(sc.sales_channel_key, -1)     as sales_channel_key
        {% if is_incremental() %}
        , ex.etl_insert_datetime                 as existing_etl_insert_datetime
        {% endif %}

    from line l

    left join sales_table st
        on l.SALESID = st.SALESID

    -- Only matches for is_return_flag = 1 rows (SALESTYPE = 4) -- a forward
    -- order line's SALESID never appears as a return header's SALESTABLE.
    left join return_header rh
        on st.REC = rh.SALESTABLE

    left join inventory_dim d
        on l.INVENTDIMID = d.InventDimID

    left join product pr
        on l.ITEMID = pr.style_number
        and d.INVENTSIZEID = pr.size
        and d.INVENTCOLORID = pr.d365_color_code

    left join customer cu
        on st.CUSTACCOUNT = cu.customer_id

    left join warehouse wh
        on d.INVENTLOCATIONID = wh.warehouse_id
        and d.inventsiteid = wh.d365_site_id

    left join sales_origin_map som
        on st.SALESORIGINID = som.sales_origin_id

    left join sales_channel sc
        on som.channel_code = sc.channel_code

    {% if is_incremental() %}
    left join existing ex
        on xxhash64(l.REC, 'D365') = ex.orders_returns_key
    {% endif %}

),

final as (

    select

    -- Core ID
    -- Surrogate key off l.REC (SalesLine's own row id), same collision-
    -- avoidance rationale as FACT_ORDER_LINE's order_line_key -- SALESID +
    -- LINENUM has known live duplicates.
          xxhash64(l.REC, 'D365')                                     as orders_returns_key
        , l.SALESID                                                   as order_id
        , cast(l.LINENUM as int)                                      as order_line_number
        , 'D365'                                                      as source_system
        , cast(null as string) as bigcommerce_order_id  -- Source once available: no confirmed field -- SalesTable.REVINTEGRATIONID is 78.5% populated but not confirmed to be BigCommerce-specific; SUNECOMMORDERID (0% populated) ruled out. Same gap as FACT_ORDER_LINE.
        , case when l.SALESTYPE = 4 then cast(l.return_header_rec as string) end as rma_id  -- No dedicated RMA-number field found on McrReturnSalesTable or SalesLine -- using the return header's own row id (REC) as the traceable identifier. Only populated for return lines; null for forward-demand lines.
        , case when l.SALESTYPE = 4 then l.ORIGINALSALESID end        as original_order_id  -- McrReturnSalesTable.ORIGINALSALESID, 89% populated on return headers (123,288 of 138,758) -- Open Decision 5, not fully resolved
        , cast(null as int) as original_order_line_number  -- Source once available: McrReturnSalesTable links at the order-header level only, no original line number captured -- Open Decision 5

    -- Dim FKs
        , cast(date_format(l.order_created_date, 'yyyyMMdd') as int)  as order_date_key
        , case when l.SHIPPINGDATEREQUESTED is not null
               then cast(date_format(l.SHIPPINGDATEREQUESTED, 'yyyyMMdd') as int)
               else null end                                          as requested_ship_date_key
        , cast(null as int) as confirmed_ship_date_key  -- Source once available: no WMS-confirmed-ship-date source registered in this project
        , cast(null as int) as actual_ship_date_key  -- Source once available: SalesLine.SALESDELIVERNOW/INVENTDELIVERNOW exist but are 0 for every row in live data (confirmed 2026-09-15) -- no usable shipment-quantity or actual-ship-date signal from D365 BYOD; needs a WMS source
        , cast(null as int) as delivery_date_key  -- Phase 2 per spec
        , case when l.SALESTYPE = 4 and l.RETURNARRIVALDATE is not null and l.RETURNARRIVALDATE > timestamp('1900-01-01')
               then cast(date_format(l.RETURNARRIVALDATE, 'yyyyMMdd') as int)
               else null end                                          as return_date_key
        , cast(null as int) as cancel_date_key  -- Source once available: no dedicated cancellation-date field found on SalesLine -- MODIFIEDDATE reflects the row's last change generally, not confirmed to be the cancellation event specifically
        , l.product_key
        , l.customer_key
        , cast(null as bigint) as ship_to_customer_key  -- Phase 2 per spec
        , l.sales_channel_key
        , l.warehouse_key
        , cast(null as bigint) as employee_sales_hierarchy_key  -- Source once available: no worker/sales-rep table found in the warehouse scan -- shared gap with FACT_ORDER_LINE and FACT_SALES_INVOICE
        , cast(null as bigint) as campaign_key  -- Phase 2 per spec
        , cast(null as bigint) as promotion_key  -- Phase 2 per spec
        , cast(null as bigint) as customer_segment_key  -- Phase 2 per spec

    -- Dates
        , cast(l.order_created_date as date)                          as order_date
        , cast(l.SHIPPINGDATEREQUESTED as date)                       as requested_ship_date
        , cast(null as date) as confirmed_ship_date  -- Source once available: see confirmed_ship_date_key
        , cast(null as date) as actual_ship_date  -- Source once available: see actual_ship_date_key
        , cast(null as date) as delivery_date  -- Phase 2 per spec
        , cast(null as date) as cancel_date  -- Source once available: see cancel_date_key
        , case when l.SALESTYPE = 4 and l.RETURNARRIVALDATE is not null and l.RETURNARRIVALDATE > timestamp('1900-01-01')
               then cast(l.RETURNARRIVALDATE as date)
               else null end                                          as return_date
        , cast(null as date) as return_request_date  -- Phase 2 per spec

    -- Status
    -- D365 SalesStatus enum (confirmed via FACT_ORDER_LINE build, 2026-09-11):
    -- 0=None, 1=Backorder, 2=Delivered, 3=Invoiced, 4=Canceled. Mapped to the
    -- spec's conformed status set as a best-effort reading, NOT yet validated
    -- with Nick/Ops -- Business Rule 7.1 explicitly calls for this validation.
    -- Backorder -> Confirmed (allocated, awaiting pick, per the spec's own
    -- description of Confirmed) and Invoiced -> Shipped (no separate shipped
    -- signal exists in this BYOD extract; invoicing is the closest available
    -- proxy for "handed to carrier"). Picked/Packed have no source at all.
        , case
            when l.SALESTYPE = 4 then 'Returned'
            when l.SALESSTATUS = 0 then 'Open'
            when l.SALESSTATUS = 1 then 'Confirmed'
            when l.SALESSTATUS = 2 then 'Delivered'
            when l.SALESSTATUS = 3 then 'Shipped'
            when l.SALESSTATUS = 4 then 'Cancelled'
            else cast(l.SALESSTATUS as string)
          end                                                         as order_line_status
        , cast(null as string) as order_type  -- Source once available: D365 SalesType enum label mapping unconfirmed (Open Decision 2, same gap as FACT_ORDER_LINE) -- is_return_flag below is derived from the raw SALESTYPE value directly, not from this label
        , case when l.SALESTYPE = 4 then true else false end          as is_return_flag
        , case when l.SALESSTATUS = 4 or l.REVQTYCANCELLED > 0 then true else false end as is_cancelled_flag
        , case when l.SALESSTATUS = 1 then true else false end        as is_backordered_flag  -- Reflects SalesStatus = Backorder as of the current ETL run, not true backorder history -- same current-state caveat as FACT_ORDER_LINE's order_line_status_at_creation
        , cast(null as boolean) as is_partial_ship_flag  -- Source once available: depends on shipped_qty, which has no source -- see actual_ship_date_key
        , cast(null as boolean) as is_replacement_flag  -- Phase 2 per spec
        , cast(null as boolean) as is_exchange_flag  -- Phase 2 per spec
        , cast(null as boolean) as is_dso_order_flag  -- Phase 2 per spec

    -- Quantities
        , l.QTYORDERED                                                 as ordered_qty
        , cast(null as decimal(18,4)) as confirmed_qty  -- Source once available: no confirmed-availability quantity field found separate from QTYORDERED
        , cast(null as decimal(18,4)) as picked_qty  -- Phase 2 per spec
        , cast(null as decimal(18,4)) as shipped_qty  -- Source once available: SalesLine.SALESDELIVERNOW/INVENTDELIVERNOW exist but are 0 for every row in live data (confirmed 2026-09-15, both SalesType 3 and 4) -- no usable shipped-quantity signal in this BYOD extract; needs a WMS source. open_qty below is null as a direct consequence.
        , cast(null as decimal(18,4)) as delivered_qty  -- Phase 2 per spec
        , l.REVQTYCANCELLED                                            as cancelled_qty
        , case when l.SALESTYPE = 4 then abs(l.QTYORDERED) end        as returned_qty  -- Return lines carry QTYORDERED negative in live data (191,916 of 216,723 return lines) -- abs() to express as a positive returned quantity per spec
        , cast(null as decimal(18,4)) as backordered_qty  -- Source once available: is_backordered_flag exists but no separate backordered-quantity field found
        , cast(null as decimal(18,4)) as open_qty  -- Source once available: formula is ordered_qty - shipped_qty - cancelled_qty per spec 7.4, and shipped_qty has no source -- see above
        , coalesce(nullif(l.SALESUNIT, ''), 'ea')                     as qty_uom

    -- Amounts
        , l.SALESPRICE                                                 as unit_price
        , l.QTYORDERED * l.SALESPRICE                                  as line_amount
        , l.LINEDISC                                                   as line_discount_amount
        , (l.QTYORDERED * l.SALESPRICE) - l.LINEDISC                   as net_line_amount
        , case when l.SALESTYPE = 4 then abs(l.QTYORDERED) * l.SALESPRICE end as return_amount
        , l.CURRENCYCODE                                               as transaction_currency_code
        , cast(null as decimal(19,8)) as fx_rate_to_usd  -- Phase 2 per spec
        , cast(null as decimal(19,4)) as net_line_amount_usd  -- Phase 2 per spec

    -- Returns
        , cast(null as string) as return_reason_code  -- Source once available: no return-reason-code field or reference table found anywhere in the BYOD extract -- Open Decision 4
        , cast(null as string) as return_reason_description  -- Source once available: see return_reason_code
        , cast(null as string) as return_reason_category  -- Source once available: see return_reason_code
        , cast(null as string) as return_disposition_code  -- Phase 2 per spec, though the raw source (SalesLine.RETURNDISPOSITIONCODEID) is already available and 88.5% populated on return lines (191,966 of 216,723) -- left null-with-note per this project's phase-boundary convention, not a real data gap
        , cast(null as string) as return_condition_code  -- Phase 2 per spec
        , cast(null as string) as refund_method  -- Phase 2 per spec

    -- B2B
        , nullif(l.PURCHORDERFORMNUM, '')                              as customer_purchase_order
        , cast(null as string) as b2b_account_number  -- Phase 2 per spec -- master is dim_customer per spec Section 6

    -- Fulfillment
        , nullif(l.DLVMODE, '')                                        as shipping_method
        , cast(null as string) as carrier_code  -- Phase 2 per spec
        , cast(null as string) as tracking_number  -- Phase 2 per spec

    -- Audit
        , 'silver_d365_sales_line + silver_d365_sales_table + silver_d365_mcr_return_sales_table' as record_source_table
        {% if is_incremental() %}
        , coalesce(l.existing_etl_insert_datetime, current_timestamp()) as etl_insert_datetime
        {% else %}
        , current_timestamp()                                         as etl_insert_datetime
        {% endif %}
        , current_timestamp()                                         as etl_update_datetime
        , l.MODIFIEDDATE                                               as etl_source_modified_datetime  -- not a spec field; incremental-merge watermark, same pattern as FACT_ORDER_LINE
        , sha2(concat_ws('||', l.SALESID, cast(l.LINENUM as string), 'D365', cast(l.SALESTYPE as string), cast(l.QTYORDERED as string), cast(l.REVQTYCANCELLED as string), coalesce(cast(l.SALESSTATUS as string), '')), 256) as row_hash

    from joined l

)

select * from final
