{{ config(
    materialized = 'incremental',
    unique_key = 'sales_invoice_key',
    incremental_strategy = 'merge',
    on_schema_change = 'sync_all_columns'
) }}

with trans as (

    select

          t.RECID
        , t.INVOICEID
        , t.LINENUM
        , t.SALESID
        , t.INVOICEDATE
        , t.ITEMID
        , t.INVENTDIMID
        , t.QTY
        , t.SALESUNIT
        , t.SALESPRICE
        , t.LINEDISC
        , t.TAXAMOUNT
        , t.CURRENCYCODE
        , t.MODIFIEDDATE
        , t.PARENTRECID

    from {{ ref('silver_d365_cust_invoice_trans') }} t

    {% if is_incremental() %}
    where t.MODIFIEDDATE > (select coalesce(max(etl_source_modified_datetime), timestamp('1900-01-01')) from {{ this }}) - interval 2 days
    {% endif %}

),

jour as (

    select

          j.REC
        , j.INVOICEID
        , j.INVOICEACCOUNT
        , j.SALESID
        , j.SALESORIGINID
        , j.PURCHASEORDER
        , j.RETURNREASONCODEID

    from {{ ref('silver_d365_cust_invoice_jour') }} j

),

sales_table as (

    select

          st.SALESID
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

    -- BigComUS -> BigComUSA fixed here 2026-09-10: the live SALESORIGINID
    -- values on CustInvoiceJour don't match the seed as originally built
    -- (390,334 of 796,338 header rows use "BigComUSA", not "BigComUS") --
    -- corrected in the seed itself (models/ref_sales_origin_map/seeds/
    -- sales_origin_map.csv), not worked around here.
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

product_cost as (

    -- fact_product_cost's real grain is product_id + cost_type + effective_date --
    -- filter to current STANDARD rows only, otherwise this join fans out (see
    -- dbt_build_conventions: any join to fact_product_cost needs this filter).
    select

          product_key
        , standard_cost_unit
        , cost_currency_code

    from {{ ref('fact_product_cost') }}
    where cost_type = 'STANDARD'
      and is_current = true

),

joined as (

    select

          tr.RECID
        , tr.INVOICEID
        , tr.LINENUM
        , tr.SALESID
        , tr.INVOICEDATE
        , tr.QTY
        , tr.SALESUNIT
        , tr.SALESPRICE
        , tr.LINEDISC
        , tr.TAXAMOUNT
        , tr.CURRENCYCODE
        , tr.MODIFIEDDATE
        , tr.PARENTRECID

        , j.INVOICEACCOUNT
        , j.PURCHASEORDER
        , j.RETURNREASONCODEID

        , st.CREATEDDATE                        as order_created_date

        , pr.product_key
        , cu.customer_key
        , wh.warehouse_key
        , sc.sales_channel_key
        , pc.standard_cost_unit
        , pc.cost_currency_code

    from trans tr

    -- Joined via PARENTRECID = jour.REC, not INVOICEID = INVOICEID: confirmed live 2026-09-10
    -- that ~107K InvoiceIds carry more than one CustInvoiceJour header row (free-standing
    -- credit memos reusing the original invoice number -- see spec Open Decision 5). A bare
    -- INVOICEID join fans trans out from 2,777,071 to 3,371,440 rows; PARENTRECID = REC is
    -- the true D365 header-line relation and matches 1:1 (2,777,071 of 2,777,071).
    left join jour j
        on tr.PARENTRECID = j.REC

    left join sales_table st
        on tr.SALESID = st.SALESID

    left join inventory_dim d
        on tr.INVENTDIMID = d.InventDimID

    left join product pr
        on tr.ITEMID = pr.style_number
        and d.INVENTSIZEID = pr.size
        and d.INVENTCOLORID = pr.d365_color_code

    left join customer cu
        on j.INVOICEACCOUNT = cu.customer_id

    left join warehouse wh
        on d.INVENTLOCATIONID = wh.warehouse_id
        and d.inventsiteid = wh.d365_site_id

    left join sales_origin_map som
        on j.SALESORIGINID = som.sales_origin_id

    left join sales_channel sc
        on som.channel_code = sc.channel_code

    left join product_cost pc
        on pr.product_key = pc.product_key

),

final as (

    select

    -- Core ID
          xxhash64(j.INVOICEID, cast(j.LINENUM as int), 'D365')      as sales_invoice_key
        , j.INVOICEID                                                as invoice_id
        , cast(j.LINENUM as int)                                     as invoice_line_number
        , j.SALESID                                                  as order_id
        , cast(null as int) as order_line_number  -- Source once available: no confirmed CustInvoiceTrans -> SalesLine join key identified -- open decision, order-to-invoice reconciliation (spec Source Mapping notes this is unconfirmed)
        , 'D365'                                                     as source_system

    -- Dim FKs
        , cast(date_format(j.INVOICEDATE, 'yyyyMMdd') as int)        as invoice_date_key
        , cast(date_format(j.order_created_date, 'yyyyMMdd') as int) as order_date_key
        , cast(null as int) as ship_date_key  -- Source once available: SalesLine.ShippingDateConfirmed -- not registered/wired yet, see README
        , j.product_key
        , j.customer_key
        , cast(null as bigint) as ship_to_customer_key  -- Phase 2 per spec -- role-playing DIM_CUSTOMER, not distinguished from bill-to yet
        , j.sales_channel_key
        , j.warehouse_key
        , cast(null as bigint) as employee_sales_hierarchy_key  -- Source once available: no worker/sales-rep table found in the warehouse scan -- NULL for B2C anyway per spec 4.5
        , cast(null as bigint) as campaign_key  -- Phase 2 per spec -- contingent on DIM_CAMPAIGN, not scoped
        , cast(null as bigint) as vendor_key  -- Phase 2 per spec -- derived from DIM_PRODUCT vendor linkage, not wired yet
        , cast(null as bigint) as customer_segment_key  -- Phase 2 per spec -- DIM_CUSTOMER_SEGMENT doesn't exist in this project yet

    -- Dates
        , cast(j.INVOICEDATE as date)                                as invoice_date
        , cast(j.order_created_date as date)                         as order_date
        , cast(null as date) as ship_date  -- Source once available: SalesLine.ShippingDateConfirmed -- not wired yet
        , cast(null as date) as requested_ship_date  -- Phase 2 per spec
        , cast(null as date) as delivery_date  -- Phase 3 per spec

    -- Quantities
        , j.QTY                                                      as invoiced_qty
        , coalesce(nullif(j.SALESUNIT, ''), 'ea')                    as qty_uom

    -- Revenue
        , j.SALESPRICE                                               as unit_price
        , j.QTY * j.SALESPRICE                                       as gross_sales_amount
        , j.LINEDISC                                                 as line_discount_amount
        , cast(null as decimal(19,4)) as header_discount_allocated  -- Source once available: Finance Decision F1 (header discount proration basis) -- open, gates margin certification per spec 4.4/12
        , j.LINEDISC                                                 as total_discount_amount  -- = line_discount_amount + header_discount_allocated once F1 is confirmed; header component contributes 0 today
        , (j.QTY * j.SALESPRICE) - j.LINEDISC                        as net_sales_amount
        , j.TAXAMOUNT                                                as tax_amount
        , cast(null as decimal(19,4)) as shipping_revenue  -- Source once available: Open Decision 3 (shipping revenue allocation basis) -- open
        , ((j.QTY * j.SALESPRICE) - j.LINEDISC) + coalesce(j.TAXAMOUNT, 0)  as total_invoice_line_amount  -- shipping_revenue term omitted while null per above

    -- Costs
        , j.standard_cost_unit
        , j.QTY * j.standard_cost_unit                               as standard_cost_amount
        , cast(null as decimal(19,4)) as landed_cost_unit  -- Phase 2 per spec
        , cast(null as decimal(19,4)) as landed_cost_amount  -- Phase 2 per spec
        , cast(null as decimal(19,4)) as freight_cost_amount  -- Phase 2 per spec
        , coalesce(j.cost_currency_code, 'USD')                      as cost_currency_code

    -- Currency
        , j.CURRENCYCODE                                             as transaction_currency_code
        , cast(null as decimal(19,8)) as fx_rate_to_usd  -- Phase 2 per spec
        , cast(null as decimal(19,4)) as net_sales_amount_usd  -- Phase 2 per spec

    -- Order Context
        , cast(null as string) as order_type  -- Source once available: D365 SalesType enum mapping not confirmed -- Open Decision area, not guessed
        , cast(null as string) as invoice_type  -- Source once available: D365 InvoiceType_W enum mapping not confirmed
        , case when j.QTY < 0 then cast(1 as boolean) else cast(0 as boolean) end as is_return_flag  -- derived from qty sign per spec Section 3 grain definition, not from invoice_type/order_type (those stay unmapped above)
        , nullif(j.RETURNREASONCODEID, '')                           as return_reason_code
        , cast(null as string) as return_reason_description  -- Source once available: no reason-code description lookup identified
        , cast(null as string) as payment_terms_code  -- Phase 2 per spec
        , cast(null as boolean) as is_intercompany_flag  -- Source once available: Open Decision 7 (include-with-flag vs. exclude) -- open, left null rather than assuming an answer

    -- B2B Context
        , nullif(j.PURCHASEORDER, '')                                as customer_purchase_order
        , cast(null as string) as b2b_account_number  -- Phase 2 per spec

    -- DSO / Loyalty
        , cast(null as boolean) as is_dso_order_flag  -- Phase 2 per spec -- Open Decision 8
        , cast(null as decimal(18,4)) as loyalty_points_earned  -- Phase 2 per spec
        , cast(null as decimal(18,4)) as loyalty_points_redeemed  -- Phase 2 per spec

    -- Audit
        , j.RECID                                                    as d365_invoice_rec_id
        , 'silver_d365_cust_invoice_trans + silver_d365_cust_invoice_jour' as record_source_table
        , current_timestamp()                                        as etl_insert_datetime
        , current_timestamp()                                        as etl_update_datetime
        , j.MODIFIEDDATE                                             as etl_source_modified_datetime
        , sha2(concat_ws('||', j.INVOICEID, cast(j.LINENUM as string), 'D365', cast(j.QTY as string), cast(j.SALESPRICE as string)), 256) as row_hash

    from joined j

)

select * from final
