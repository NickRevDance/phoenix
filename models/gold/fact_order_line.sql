{{ config(
    materialized = 'incremental',
    unique_key = 'order_line_key',
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
        , l.QTYORDERED
        , l.SALESPRICE
        , l.SALESUNIT
        , l.LINEDISC
        , l.CURRENCYCODE
        , l.SALESSTATUS
        , l.SHIPPINGDATEREQUESTED
        , l.MODIFIEDDATE

    from {{ ref('silver_d365_sales_line') }} l

    -- Business rule 7.2 (spec): forward-demand lines only. Only SALESTYPE 3/4
    -- exist in live data at all; 4 correlates 100% with a non-zero RETURNSTATUS
    -- (confirmed live 2026-09-11: all 215,909 SALESTYPE=4 lines carry
    -- RETURNSTATUS in {1,2,4,5,6}, all 2,588,292 SALESTYPE=3 lines carry
    -- RETURNSTATUS=0) -- treated as the Return population per spec Section 3,
    -- excluded here. Official SalesType enum label mapping unconfirmed
    -- (Open Decision 2) -- order_type stays null below rather than guessing
    -- a label off this inference.
    where l.SALESTYPE = 3

    {% if is_incremental() %}
    and l.MODIFIEDDATE > (select coalesce(max(etl_source_modified_datetime), timestamp('1900-01-01')) from {{ this }}) - interval 2 days
    {% endif %}

),

sales_table as (

    select

          st.SALESID
        , st.CUSTACCOUNT
        , st.SALESORIGINID
        , st.DLVMODE
        , st.PURCHORDERFORMNUM
        , st.CREATEDDATE

    from {{ ref('silver_d365_sales_table') }} st

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

    -- Same live-data gap fact_sales_invoice already flagged and fixed at
    -- the seed level (models/ref_sales_origin_map/seeds/sales_origin_map.csv,
    -- BigComUS -> BigComUSA): as of 2026-09-11 that reseed still hasn't run,
    -- so BigComUSA (1,689,974 of 2,588,287 order lines, 65%) doesn't match
    -- here yet either. Not re-fixed in this build -- same open fix, same
    -- table. See README.
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

joined as (

    select

          l.REC
        , l.SALESID
        , l.LINENUM
        , l.QTYORDERED
        , l.SALESPRICE
        , l.SALESUNIT
        , l.LINEDISC
        , l.CURRENCYCODE
        , l.SALESSTATUS
        , l.SHIPPINGDATEREQUESTED
        , l.MODIFIEDDATE

        , st.CUSTACCOUNT
        , st.SALESORIGINID
        , st.DLVMODE
        , st.PURCHORDERFORMNUM
        , st.CREATEDDATE                         as order_created_date

        , d.INVENTLOCATIONID
        , pr.product_key
        , cu.customer_key
        , wh.warehouse_key
        , sc.sales_channel_key

    from line l

    left join sales_table st
        on l.SALESID = st.SALESID

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

),

final as (

    select

    -- Core ID
    -- Surrogate key built off l.REC (SalesLine's own row id, confirmed 100%
    -- unique live: 2,804,201 of 2,804,201), not the SALESID+LINENUM business
    -- key -- 2 order lines in live data (SO-3618976 line 1 x3,
    -- SO-3370595 line 1 x2) genuinely repeat that combination, which would
    -- collide a business-key-based hash the same way fact_sales_invoice's
    -- INVOICEID+LINENUM key collided and was fixed to RECID on 2026-09-11.
          xxhash64(l.REC, 'D365')                                    as order_line_key
        , l.SALESID                                                  as order_id
        , cast(l.LINENUM as int)                                     as order_line_number
        , 'D365'                                                     as source_system
        , cast(null as string) as bigcommerce_order_id  -- Source once available: no confirmed field -- SalesTable.REVINTEGRATIONID is 78.5% populated but not confirmed to be BigCommerce-specific; SUNECOMMORDERID (0% populated) ruled out
        , cast(null as string) as order_type  -- Source once available: D365 SalesType enum label mapping unconfirmed (Open Decision 2) -- see filter comment above

    -- Dim FKs
        , cast(date_format(l.order_created_date, 'yyyyMMdd') as int)  as order_date_key
        , case when l.SHIPPINGDATEREQUESTED is not null
               then cast(date_format(l.SHIPPINGDATEREQUESTED, 'yyyyMMdd') as int)
               else null end                                          as requested_ship_date_key
        , l.product_key
        , l.customer_key
        , cast(null as bigint) as ship_to_customer_key  -- Phase 2 per spec
        , l.sales_channel_key
        , l.warehouse_key
        , cast(null as bigint) as employee_sales_hierarchy_key  -- Source once available: no worker/sales-rep table found in the warehouse scan -- shared gap with fact_sales_invoice
        , cast(null as bigint) as campaign_key  -- Phase 2 per spec
        , cast(null as bigint) as promotion_key  -- Phase 2 per spec
        , cast(null as bigint) as customer_segment_key  -- Phase 2 per spec -- DIM_CUSTOMER_SEGMENT doesn't exist in this project yet

    -- Dates
        , cast(l.order_created_date as date)                         as order_date
        , cast(l.SHIPPINGDATEREQUESTED as date)                      as requested_ship_date
        , cast(null as date) as requested_delivery_date  -- Phase 2 per spec

    -- Status
    -- D365 SalesStatus enum: 0=None, 1=Backorder, 2=Delivered, 3=Invoiced,
    -- 4=Canceled (confirmed 2026-09-11). This is the line's CURRENT status
    -- as of this initial load, not a true point-in-time-at-creation value --
    -- D365 BYOD carries no status-change history, so an already-invoiced
    -- historical order line (97.5% of this population) reads as "Invoiced"
    -- here rather than whatever it was the day it was placed. Spec Section
    -- 7.5 anticipates this exact late-arriving-line scenario.
        , case l.SALESSTATUS
            when 0 then 'None'
            when 1 then 'Backorder'
            when 2 then 'Delivered'
            when 3 then 'Invoiced'
            when 4 then 'Canceled'
            else cast(l.SALESSTATUS as string)
          end                                                         as order_line_status_at_creation
        , cast(null as boolean) as is_backordered_at_creation_flag  -- Source once available: Open Decision 6 -- SALESSTATUS=1 ("Backorder") exists but reflects current, not at-creation, state
        , cast(null as boolean) as is_expedited_flag  -- Source once available: no expedite indicator found (DLVMODE is a shipping method code, not an urgency flag)
        , cast(null as boolean) as is_dso_order_flag  -- Phase 2 per spec -- Open Decision 7

    -- Quantities
        , l.QTYORDERED                                                as ordered_qty
        , coalesce(nullif(l.SALESUNIT, ''), 'ea')                    as qty_uom

    -- Amounts
        , l.SALESPRICE                                                as unit_price
        , l.QTYORDERED * l.SALESPRICE                                 as line_amount
        , l.LINEDISC                                                  as line_discount_amount  -- LINEDISC is already a line-level dollar amount live (avg $0.73, 9.5% of lines nonzero); LINEPERCENT is not used in this data (nonzero on 1 of 2,588,292 lines)
        , (l.QTYORDERED * l.SALESPRICE) - l.LINEDISC                  as net_line_amount
        , l.CURRENCYCODE                                              as transaction_currency_code
        , cast(null as decimal(19,8)) as fx_rate_to_usd  -- Phase 2 per spec
        , cast(null as decimal(19,4)) as net_line_amount_usd  -- Phase 2 per spec

    -- B2B Context
        , nullif(l.PURCHORDERFORMNUM, '')                             as customer_purchase_order

    -- Fulfillment Context
        , nullif(l.DLVMODE, '')                                       as shipping_method  -- raw D365 delivery-mode code; no code-to-name lookup table found
        , nullif(l.INVENTLOCATIONID, '')                              as warehouse_id_at_order

    -- Audit
        , 'silver_d365_sales_line + silver_d365_sales_table'          as record_source_table
        , current_timestamp()                                        as etl_insert_datetime
        , l.MODIFIEDDATE                                              as etl_source_modified_datetime  -- not a spec field; needed as the incremental-merge watermark (spec 6/Audit says etl_insert_datetime is the only timestamp needed since rows are immutable, but the ETL mechanics still need a change-detection column upstream)
        , sha2(concat_ws('||', l.SALESID, cast(l.LINENUM as string), 'D365', cast(l.QTYORDERED as string), cast(l.SALESPRICE as string)), 256) as row_hash

    from joined l

)

select * from final
