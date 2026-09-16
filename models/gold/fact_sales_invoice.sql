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
        , t.LINEAMOUNT
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

barcode as (

    -- 2026-09-16 fix (Chris review, item 1): style+size+color through
    -- dim_product is the same join shape that left ~10% NULL product_key on
    -- the inventory snapshot fact. Spec v1.2 and the EDW-20 fact_product_price
    -- rebuild both use the barcode path instead: ITEMID + INVENTDIMID resolve
    -- through D365's item-barcode table to a UPC, hashed identically to
    -- DIM_PRODUCT's own product_key formula (md5(ifnull(upc,'0'))) so the two
    -- line up without a second lookup table. item_barcode's own InventDimID
    -- is a reference-level dimension record, not the transactional one on
    -- CustInvoiceTrans -- confirmed live 2026-09-16 that a direct InventDimID
    -- join matches 0 rows even though every ITEMID overlaps. Resolved through
    -- silver_d365_inventory_dim to size/color instead, then matched on
    -- ITEMID + size + color against the transactional line's own size/color
    -- (same inventory_dim CTE this model already joins for warehouse) --
    -- 99.77% resolution confirmed live on the sibling fact_order_line
    -- population, vs. 97.95% via the old style+size+color-to-dim_product
    -- path. Most-recently-modified barcode wins when more than one exists
    -- for the same item + size + color.
    select

          b.ITEMID
        , bd.INVENTSIZEID
        , bd.INVENTCOLORID
        , b.ITEMBARCODE
        , row_number() over (
            partition by b.ITEMID, bd.INVENTSIZEID, bd.INVENTCOLORID
            order by b.MODIFIEDDATE desc
          ) as rn

    from {{ ref('silver_d365_item_barcode') }} b

    left join {{ ref('silver_d365_inventory_dim') }} bd
        on b.INVENTDIMID = bd.InventDimID

),

customer as (

    -- Refs the gold dim_customer directly, same convention as fact_order_line.
    -- DIM_CUSTOMER_SEGMENT's profile no longer derives order recency from this
    -- fact table (it reads the raw D365 invoice silver tables itself -- see
    -- silver_stage_customer_segment_profile.sql), so there's no cycle here to
    -- avoid.
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
    -- Joined below on product_id (raw D365 ItemId), not product_key, per the
    -- EDW-12 sign-off recorded in spec v1.2 Section 10 -- fact_product_cost's
    -- real grain is product_id-level, and going through dim_product's
    -- style/size/color-resolved product_key was never the correct key for
    -- this join.
    select

          product_id
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
        , tr.LINEAMOUNT
        , tr.TAXAMOUNT
        , tr.CURRENCYCODE
        , tr.MODIFIEDDATE
        , tr.PARENTRECID

        , j.INVOICEACCOUNT
        , j.PURCHASEORDER
        , j.RETURNREASONCODEID
        , j.SALESORIGINID

        , st.CREATEDDATE                        as order_created_date

        , case when bar.ITEMBARCODE is not null
               then md5(concat_ws('|', bar.ITEMBARCODE))
               else '-1'
          end                                    as product_key
        , cu.customer_key
        , wh.warehouse_key
        , coalesce(sc.sales_channel_key, -1) as sales_channel_key  -- v1.2 (EDW-15/16, adopted): sales_channel_key is never NULL -- unmapped/blank origins resolve to dim_sales_channel's reserved -1 UNKNOWN member. The 10-14% of lines on a *mapped* origin that still come back with no channel (header-join loss, not an unmapped-origin gap) is an open EDW-23 review item, not fixed by this coalesce.
        , nullif(j.SALESORIGINID, '') as source_sales_origin_id  -- v1.1 (EDW-16, Decision 4): raw D365 origin carried on the fact as a non-key lineage attribute, so an unmapped/blank row can be traced without a join back to silver.
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

    left join barcode bar
        on tr.ITEMID = bar.ITEMID
        and d.INVENTSIZEID = bar.INVENTSIZEID
        and d.INVENTCOLORID = bar.INVENTCOLORID
        and bar.rn = 1

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
        on tr.ITEMID = pc.product_id

),

final as (

    select

    -- Core ID
          xxhash64(j.RECID, 'D365')                                  as sales_invoice_key  -- fixed 2026-09-11: was xxhash64(INVOICEID, LINENUM, 'D365'). That collides whenever a credit memo reuses the original invoice's INVOICEID with an overlapping LINENUM under a *different* CustInvoiceJour header (the same PARENTRECID fan-out this join was already built to handle, per the comment above) -- confirmed live: 107,248 distinct sales_invoice_key values were duplicated across 214,676 rows out of 2,780,550. j.RECID is CustInvoiceTrans's own row identifier and is 100% unique on the source table (2,780,780 of 2,780,780, confirmed live 2026-09-11) -- INVOICEID/LINENUM stay below as descriptive attributes, just no longer the key's inputs.
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
        , j.source_sales_origin_id
        , j.warehouse_key
        , cast(-1 as bigint) as employee_sales_hierarchy_key  -- 2026-09-16 fix (Chris review, Aug 5 note): coalesced to the reserved -1 UNKNOWN member rather than left null -- no worker/sales-rep table found in the warehouse scan; still applies to B2C per spec 4.5
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
        , cast(j.QTY * j.LINEDISC as decimal(32,6))                   as line_discount_amount  -- 2026-09-16 fix (Chris review): LINEDISC is a per-unit amount, not a line total -- the prior LINEDISC-as-is value gave a discounted return line's discount to the credit instead of subtracting it, and undercounted a discounted multi-unit line to one unit's discount. Missed CustInvoiceJour.SALESBALANCE on 62K of 802K invoices (~$6.9M absolute) under the old formula. QTY * LINEDISC ties LINEAMOUNT on 99.2% of lines (a ~21K-line PRICEUNIT=0-with-no-discount residual is unchased -- see README).
        , cast(null as decimal(19,4)) as header_discount_allocated  -- Source once available: Finance Decision F1 (header discount proration basis) -- open, gates margin certification per spec 4.4/12
        , cast(j.QTY * j.LINEDISC as decimal(32,6))                   as total_discount_amount  -- = line_discount_amount + header_discount_allocated once F1 is confirmed; header component contributes 0 today
        , cast(j.LINEAMOUNT as decimal(38,6))                        as net_sales_amount  -- 2026-09-16 fix: sourced from CustInvoiceTrans.LINEAMOUNT directly (source truth) instead of re-derived as QTY * SALESPRICE - LINEDISC -- sum(LINEAMOUNT) ties CustInvoiceJour.SALESBALANCE on every invoice
        , j.TAXAMOUNT                                                as tax_amount
        , cast(null as decimal(19,4)) as shipping_revenue  -- Source once available: Open Decision 3 (shipping revenue allocation basis) -- open
        , cast(j.LINEAMOUNT + coalesce(j.TAXAMOUNT, 0) as decimal(38,6)) as total_invoice_line_amount  -- shipping_revenue term omitted while null per above; base term now net_sales_amount (LINEAMOUNT) rather than the re-derived formula

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
        , cast(null as decimal(18,4)) as loyalty_points_earned  -- Phase 2 per spec v1.2: source is FACT_LOYALTY_TRANSACTION (EDW-78, order-level earn event), allocated to lines pro-rata by net_sales_amount over qualifying lines on the order (spec 4.8); qualifying-spend scope (costume-only vs. all products) open with Marketing. Stays a typed NULL until FACT_LOYALTY_TRANSACTION exists.
        -- loyalty_points_redeemed retired per spec v1.2 (Revolution Rewards two-step Rev Cash model, adopted 2026-08-19): points convert to a certificate and are spent as tender, so there's no invoice-line redemption event to source. Certificate burn is a FACT_PAYMENT_TRANSACTION event instead -- column dropped, not left as a null scaffold.

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
