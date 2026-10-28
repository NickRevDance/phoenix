{{ config(
    materialized = 'incremental',
    unique_key = 'sales_invoice_key',
    incremental_strategy = 'merge',
    on_schema_change = 'sync_all_columns'
) }}

with posted_cost as (

    -- EDW-182: D365's posted cost on the invoice line's InventTrans legs, the COGS basis (decision
    -- record I6: inventory and COGS at D365 moving average). The line reaches its legs through its
    -- own INVENTTRANSID (InventTransOrigin.INVENTTRANSID, unique on the origin table) and the
    -- INVOICEID the leg was invoiced under, so a sales line invoiced in parts (8,336 lines on two
    -- or more invoices, Oct 22 2026) takes only the legs of this invoice. Sale lines carry sold
    -- legs (STATUSISSUE = 1, negative quantity and cost); credit lines carry the returned receipt
    -- legs (STATUSRECEIPT = 1, positive quantity and cost), so -(posted + adjustment) carries the
    -- line's sign on both. Several legs per line are normal (231,289 lines, up to 30) and are
    -- summed. Checked Oct 22 2026 over the whole fact: 2,877,847 of 2,877,869 sales order lines
    -- match (the other 22 have no INVENTTRANSID); no leg disagrees with its line's sign; every leg
    -- is posted in USD; COSTAMOUNTSTD equals COSTAMOUNTPOSTED on every leg, so this is also the
    -- legacy f_InvoicesD365 COGS basis (monthly within $10K). COSTAMOUNTADJUSTMENT is zero on
    -- every sold leg (moving average, no inventory close) and non-zero only on 30,557 returned
    -- legs, posting up to months after the credit; trans re-reads lines whose legs changed.
    -- Leg quantity equals the line's on all but 32 lines, where silver holds both the legs D365
    -- replaced on a re-split (Oct 12 and 14 2026) and their replacements; the amount column
    -- guards that with the unit cost x invoiced_qty.
    select

          o.INVENTTRANSID
        , it.INVOICEID
        , sum(coalesce(it.COSTAMOUNTPOSTED, 0) + coalesce(it.COSTAMOUNTADJUSTMENT, 0)) as posted_cost_amount
        , sum(it.QTY)                                                                 as posted_qty
        , max(it.MODIFIEDDATE)                                                        as legs_modified_datetime

    from {{ ref('silver_d365_inventory_trans') }} it

    inner join {{ ref('silver_d365_inventory_trans_origin') }} o
        on it.INVENTTRANSORIGIN = o.RECID

    where nullif(it.INVOICEID, '') is not null
      and (it.STATUSISSUE = 1 or it.STATUSRECEIPT = 1)  -- financially posted legs only

    group by 1, 2

),

trans as (

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
        , t.LINEAMOUNTMST  -- EDW-169: the line amount as booked in the accounting currency (USD)
        , t.TAXAMOUNT
        , t.CURRENCYCODE
        , t.MODIFIEDDATE
        , t.PARENTRECID
        , t.INVENTTRANSID  -- EDW-169: link to the sales line (unique on SalesLine)

    from {{ ref('silver_d365_cust_invoice_trans') }} t

    {% if is_incremental() %}
    where (
        t.MODIFIEDDATE > (select coalesce(max(etl_source_modified_datetime), timestamp('1900-01-01')) from {{ this }}) - interval 2 days
        -- EDW-134 self-heal: re-pull invoice lines that still hold an Unknown product (EDW-173: match on the line RECID, not the header PARENTRECID)
        or t.RECID in (select d365_invoice_rec_id from {{ this }} where product_key = '-1')
        -- EDW-182: lines whose InventTrans legs changed inside the lookback, so a cost adjustment
        -- posted to a returned leg after the credit, or a leg that landed after its line, restates
        -- the posted cost. Same shape as the other facts' lookback vars.
        or nullif(t.INVENTTRANSID, '') in (
            select pc.INVENTTRANSID
            from posted_cost pc
            where pc.legs_modified_datetime > (select coalesce(max(etl_source_modified_datetime), timestamp('1900-01-01')) from {{ this }}) - interval {{ var('sales_invoice_cost_lookback_days', 2) }} days
        )
        {% if 'moving_avg_cost_amount' in (adapter.get_columns_in_relation(this) | map(attribute='name') | map('lower') | list) %}
        -- EDW-182 self-heal: recent sales order lines still without a posted cost (legs that
        -- reached silver more than the lookback after the line did). Bounded by invoice date so
        -- history filled in place (D012) is never re-read here. Guarded on the column existing,
        -- because this select runs before sync_all_columns adds the column on the first merge.
        or t.RECID in (
            select d365_invoice_rec_id
            from {{ this }}
            where moving_avg_cost_amount is null
              and invoice_type = 'Sales Order'
              and invoice_date >= current_date() - interval {{ var('sales_invoice_cost_heal_days', 7) }} days
        )
        {% endif %}
    )
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
        , j.EXCHRATE  -- EDW-169: posted exchange rate, per 100 units of the invoice currency (100 on USD)
        , j.PAYMENT  -- EDW-59: payment terms on the invoice header
        , j.INTERCOMPANYPOSTED  -- EDW-59: intercompany posting flag
        , j.CUSTGROUP  -- EDW-59: the invoice account's customer group as posted on the header

    from {{ ref('silver_d365_cust_invoice_jour') }} j

),

sales_line as (

    -- EDW-169: Nimbly website fee and commission, per unit on the sales line. Reached
    -- through INVENTTRANSID, which is unique on SalesLine (2,901,485 of 2,901,485, checked
    -- Oct 14 2026), so this join cannot fan out. Matched rows agree on item and order on
    -- every line since Jul 2023. Return sales lines carry the fields too, so credit lines
    -- reach them the same way. Also carries the custom print fee, which is a line amount.
    select

          sl.INVENTTRANSID
        , sl.REC
        , sl.QTYORDERED
        , sl.REVWEBSITEFEE
        , sl.REVCOMMISSION
        , sl.REVNETCUSTOMPRINTFEE
        , sl.SHIPPINGDATEREQUESTED  -- EDW-59: requested ship date on the originating sales line

    from {{ ref('silver_d365_sales_line') }} sl
    where nullif(sl.INVENTTRANSID, '') is not null

),

sales_table as (

    select

          st.SALESID
        , st.CREATEDDATE
        , st.PAYMMODE  -- EDW-59: tender on the originating order (the invoice header carries none)

    from {{ ref('silver_d365_sales_table') }} st

),

-- EDW-184: the sales orders that replace a return, the same rule as fact_orders_returns (EDW-58,
-- spec 4.11): every order named in a return header's RETURNREPLACEMENTID. D365 posts the sale
-- lines on these orders to the returns account, so the Executive Summary counts them as returns
-- (BS-367 decision D8). Read from the full header table, so a line gets its flag on any run; the
-- replacement order exists before it is invoiced, so the flag is known when the line lands.
replacement_order as (

    select distinct

          rt.RETURNREPLACEMENTID as SALESID

    from {{ ref('silver_d365_sales_table') }} rt
    where rt.SALESTYPE = 4
      and rt.RETURNREPLACEMENTCREATED = 1
      and nullif(rt.RETURNREPLACEMENTID, '') is not null
      and coalesce(rt.is_deleted, 0) = 0  -- EDW-177: silver keeps deleted headers; a deleted return names no replacement

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

    -- EDW-134: dim membership check for product_key resolution.
    select product_key
    from {{ ref('dim_product') }}
    where version_number = 1
      and product_key <> '-1'

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
        , customer_segment_key  -- EDW-59: Type 1 on dim_customer, so this is the customer's segment today

    from {{ ref('dim_customer') }}
    where version_number = 1
      and source_system = 'D365'

),

customer_dso as (

    -- EDW-59 (spec 4.13): the DSO flag on the DIM_CUSTOMER version in effect at the invoice
    -- date. is_dso_member_flag is Type 2, so the version ranges hold the membership history and
    -- the flag rebuilds the same on a full refresh. Ranges are rebuilt from each version's start
    -- date, the same way as the fx_rate CTE on fact_orders_returns: each version runs to the day
    -- before the next one starts, the first version reaches back to 1900-01-01 (history before
    -- the first snapshot reads the first version) and the last stays open (a closed, hard-deleted
    -- account keeps its last version). Contiguous by construction, so the join cannot fan out.
    select

          c.customer_key
        , c.is_dso_member_flag
        , case
            when row_number() over (partition by c.customer_key order by c.effective_start_datetime, c.version_number desc) = 1
            then date'1900-01-01'
            else cast(c.effective_start_datetime as date)
          end                                                       as range_start_date
        , coalesce(
              lead(cast(c.effective_start_datetime as date)) over (partition by c.customer_key order by c.effective_start_datetime, c.version_number desc)
            , date'9999-12-31'
          )                                                         as range_end_date  -- exclusive

    from {{ ref('dim_customer') }} c
    where c.source_system = 'D365'

),

{% if is_incremental() %}
-- EDW-59 / EDW-132: values held once written. A matched row keeps its etl_insert_datetime, and
-- keeps the customer_segment_key it was written with while its customer is unchanged (spec 4.14:
-- the segment at the time the line was inserted). A NULL is not held, so a line written without
-- a segment takes one on its next merge. A full refresh restates the segment to the customer's
-- segment on the day of the refresh, the same way standard_cost_unit restates (spec Section 7).
existing as (

    select

          sales_invoice_key
        , customer_key
        , customer_segment_key
        , etl_insert_datetime

    from {{ this }}

),
{% endif %}

warehouse as (

    select

          warehouse_key
        , warehouse_id
        , d365_site_id

    from {{ ref('dim_warehouse') }}
    where version_number = 1  -- EDW-90 item 4: fact key resolution resolves against the latest version, not is_current_row

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
        , tr.LINEAMOUNTMST
        , tr.TAXAMOUNT
        , tr.CURRENCYCODE
        , tr.MODIFIEDDATE
        , tr.PARENTRECID

        , j.INVOICEACCOUNT
        , j.PURCHASEORDER
        , j.RETURNREASONCODEID
        , j.SALESORIGINID
        , j.PAYMENT
        , j.INTERCOMPANYPOSTED
        , j.CUSTGROUP
        , st.PAYMMODE
        , sl.SHIPPINGDATEREQUESTED

        -- EDW-169: posted rate to USD. 1 on USD (EXCHRATE = 100 on every USD header).
        , case
            when tr.CURRENCYCODE = 'USD' then cast(1 as decimal(19,8))
            else cast(nullif(j.EXCHRATE, 0) / 100 as decimal(19,8))
          end                                   as fx_rate_to_usd
        -- EDW-169: per-unit Nimbly fields; 0 where the line has no sales line (free text lines)
        , coalesce(sl.REVWEBSITEFEE, 0)          as nimbly_fee_unit
        , coalesce(sl.REVCOMMISSION, 0)          as nimbly_commission_unit
        -- EDW-169: custom print fee is a line amount on the sales line, so the invoice line takes
        -- its share by invoiced over ordered quantity (the whole amount on a fully invoiced line)
        , coalesce(sl.REVNETCUSTOMPRINTFEE * tr.QTY / nullif(sl.QTYORDERED, 0), 0) as custom_print_fee_share
        , cast(sl.REC as bigint)                 as d365_sales_line_rec_id

        , st.CREATEDDATE                        as order_created_date

        -- EDW-134: UPCs missing from dim_product resolve to Unknown ('-1'); UPC kept in unresolved_upc
        , coalesce(prod.product_key, '-1')   as product_key
        , case when prod.product_key is null then bar.ITEMBARCODE end as unresolved_upc
        , cu.customer_key
        , cu.customer_segment_key                as current_customer_segment_key  -- EDW-59
        , dso.is_dso_member_flag                 as dso_flag_at_invoice  -- EDW-59
        {% if is_incremental() %}
        , ex.customer_key                        as existing_customer_key
        , ex.customer_segment_key                as existing_customer_segment_key
        , ex.etl_insert_datetime                 as existing_etl_insert_datetime
        {% endif %}
        , wh.warehouse_key
        , coalesce(sc.sales_channel_key, -1) as sales_channel_key  -- v1.2 (EDW-15/16, adopted): sales_channel_key is never NULL -- unmapped/blank origins resolve to dim_sales_channel's reserved -1 UNKNOWN member. The 10-14% of lines on a *mapped* origin that still come back with no channel (header-join loss, not an unmapped-origin gap) is an open EDW-23 review item, not fixed by this coalesce.
        , nullif(j.SALESORIGINID, '') as source_sales_origin_id  -- v1.1 (EDW-16, Decision 4): raw D365 origin carried on the fact as a non-key lineage attribute, so an unmapped/blank row can be traced without a join back to silver.
        , pc.standard_cost_unit
        , pc.cost_currency_code
        , pst.posted_cost_amount  -- EDW-182
        , pst.posted_qty          -- EDW-182
        , ro.SALESID is not null  as is_replacement_order  -- EDW-184

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

    -- EDW-184: one row per order (distinct above), so this join cannot fan out.
    left join replacement_order ro
        on tr.SALESID = ro.SALESID

    left join inventory_dim d
        on tr.INVENTDIMID = d.InventDimID

    left join barcode bar
        on tr.ITEMID = bar.ITEMID
        and d.INVENTSIZEID = bar.INVENTSIZEID
        and d.INVENTCOLORID = bar.INVENTCOLORID
        and bar.rn = 1

    left join product prod
        on md5(concat_ws('|', bar.ITEMBARCODE)) = prod.product_key

    left join customer cu
        on j.INVOICEACCOUNT = cu.customer_id

    -- EDW-59: the customer version in effect on the invoice date (DSO flag)
    left join customer_dso dso
        on cu.customer_key = dso.customer_key
        and cast(tr.INVOICEDATE as date) >= dso.range_start_date
        and cast(tr.INVOICEDATE as date) < dso.range_end_date

    {% if is_incremental() %}
    left join existing ex
        on xxhash64(tr.RECID, 'D365') = ex.sales_invoice_key
    {% endif %}

    left join warehouse wh
        on d.INVENTLOCATIONID = wh.warehouse_id
        and d.inventsiteid = wh.d365_site_id

    left join sales_origin_map som
        on j.SALESORIGINID = som.sales_origin_id

    left join sales_channel sc
        on som.channel_code = sc.channel_code

    left join product_cost pc
        on tr.ITEMID = pc.product_id

    -- EDW-182: one row per INVENTTRANSID + INVOICEID (grouped above), and no pair lands on more
    -- than one invoice line (checked Oct 22 2026), so this join cannot fan out.
    left join posted_cost pst
        on nullif(tr.INVENTTRANSID, '') = pst.INVENTTRANSID
        and tr.INVOICEID = pst.INVOICEID

    left join sales_line sl
        on nullif(tr.INVENTTRANSID, '') = sl.INVENTTRANSID

),

final as (

    select

    -- Core ID
          xxhash64(j.RECID, 'D365')                                  as sales_invoice_key  -- fixed 2026-09-11: was xxhash64(INVOICEID, LINENUM, 'D365'). That collides whenever a credit memo reuses the original invoice's INVOICEID with an overlapping LINENUM under a *different* CustInvoiceJour header (the same PARENTRECID fan-out this join was already built to handle, per the comment above) -- confirmed live: 107,248 distinct sales_invoice_key values were duplicated across 214,676 rows out of 2,780,550. j.RECID is CustInvoiceTrans's own row identifier and is 100% unique on the source table (2,780,780 of 2,780,780, confirmed live 2026-09-11) -- INVOICEID/LINENUM stay below as descriptive attributes, just no longer the key's inputs.
        , j.INVOICEID                                                as invoice_id
        , cast(j.LINENUM as int)                                     as invoice_line_number
        , nullif(j.SALESID, '')                                      as order_id  -- EDW-59: NULL on free text lines (was a blank string)
        , cast(null as int) as order_line_number  -- EDW-169: the link to the sales line is now confirmed (INVENTTRANSID, see d365_sales_line_rec_id). Stays a typed NULL INT for now: FACT_DISCOUNT_APPLICATION passes this column through, and filling it at the order facts' DECIMAL(10,4) changes that fact's column type too, so it lands with the discount fact's order-line keys.
        , j.d365_sales_line_rec_id  -- EDW-169: SalesLine RECID through INVENTTRANSID; joins to d365_sales_line_rec_id on FACT_ORDER_LINE and FACT_ORDERS_RETURNS. NULL on free text lines and the few with no link.
        , 'D365'                                                     as source_system

    -- Dim FKs
        , cast(date_format(j.INVOICEDATE, 'yyyyMMdd') as int)        as invoice_date_key
        , cast(date_format(j.order_created_date, 'yyyyMMdd') as int) as order_date_key
        , cast(null as int) as ship_date_key  -- Source once available: SalesLine.ShippingDateConfirmed -- not registered/wired yet, see README
        , j.product_key
        , j.unresolved_upc
        , j.customer_key
    -- ship_to_customer_key removed (retired, spec v1.4 O8; EDW-59): ship-to geography replaces it once LogisticsPostalAddress is ingested.
        , j.sales_channel_key
        , j.source_sales_origin_id
        , j.warehouse_key
        , cast(-1 as bigint) as employee_sales_hierarchy_key  -- 2026-09-16 fix (Chris review, Aug 5 note): coalesced to the reserved -1 UNKNOWN member rather than left null -- no worker/sales-rep table found in the warehouse scan; still applies to B2C per spec 4.5
        , cast(null as bigint) as campaign_key  -- Phase 2 per spec -- contingent on DIM_CAMPAIGN, not scoped
        , cast(null as bigint) as vendor_key  -- Phase 2 per spec -- derived from DIM_PRODUCT vendor linkage, not wired yet
        {% if is_incremental() %}
        , case
            when j.existing_customer_key = j.customer_key
            then coalesce(j.existing_customer_segment_key, j.current_customer_segment_key)
            else j.current_customer_segment_key
          end                                                        as customer_segment_key
        {% else %}
        , j.current_customer_segment_key                             as customer_segment_key
        {% endif %}
        -- EDW-59 (spec 4.14): the customer's segment when the line is written, held after that (see
        -- the existing CTE). DIM_CUSTOMER_SEGMENT has no -1 member, so a line on the -1 customer reads NULL.

    -- Dates
        , cast(j.INVOICEDATE as date)                                as invoice_date
        , cast(j.order_created_date as date)                         as order_date
        , cast(null as date) as ship_date  -- Source once available: SalesLine.ShippingDateConfirmed -- not wired yet
        , case when j.SHIPPINGDATEREQUESTED > timestamp('1901-01-01') and j.SHIPPINGDATEREQUESTED < timestamp('2040-01-01')
               then cast(j.SHIPPINGDATEREQUESTED as date)
          end                                                        as requested_ship_date  -- EDW-59: SalesLine.SHIPPINGDATEREQUESTED through INVENTTRANSID (d365_sales_line_rec_id). Placeholder dates read NULL (spec 7.6, same bounds as the order facts). NULL on free text lines.
        , cast(null as date) as delivery_date  -- Phase 3 per spec

    -- Quantities
        , j.QTY                                                      as invoiced_qty
        , coalesce(nullif(j.SALESUNIT, ''), 'ea')                    as qty_uom

    -- Revenue
        , j.SALESPRICE                                               as unit_price
        , {{ amount("case when nullif(j.SALESID, '') is null then j.LINEAMOUNT else j.QTY * j.SALESPRICE end") }} as gross_sales_amount  -- EDW-59 (spec 4.9): the line amount on free text lines, where PRICEUNIT is 0 and quantity x price reads about zero; quantity x price on sales order lines as before. decimal(38,6), the type the column already has.
        , {{ amount('j.QTY * j.LINEDISC') }}                          as line_discount_amount  -- 2026-09-16 fix (Chris review): LINEDISC is a per-unit amount, not a line total -- the prior LINEDISC-as-is value gave a discounted return line's discount to the credit instead of subtracting it, and undercounted a discounted multi-unit line to one unit's discount. Missed CustInvoiceJour.SALESBALANCE on 62K of 802K invoices (~$6.9M absolute) under the old formula. QTY * LINEDISC ties LINEAMOUNT on 99.2% of lines (a ~21K-line PRICEUNIT=0-with-no-discount residual is unchased -- see README).
        , cast(null as decimal(19,4)) as header_discount_allocated  -- Source once available: Finance Decision F1 (header discount proration basis) -- open, gates margin certification per spec 4.4/12
        , {{ amount('j.QTY * j.LINEDISC') }}                          as total_discount_amount  -- = line_discount_amount + header_discount_allocated once F1 is confirmed; header component contributes 0 today
        , {{ amount('j.LINEAMOUNT') }}                                as net_sales_amount  -- 2026-09-16 fix: sourced from CustInvoiceTrans.LINEAMOUNT directly (source truth) instead of re-derived as QTY * SALESPRICE - LINEDISC -- sum(LINEAMOUNT) ties CustInvoiceJour.SALESBALANCE on every invoice
        , j.TAXAMOUNT                                                as tax_amount
        , cast(null as decimal(19,4)) as shipping_revenue  -- Source once available: Open Decision 3 (shipping revenue allocation basis) -- open
        , {{ amount('j.LINEAMOUNT + coalesce(j.TAXAMOUNT, 0)') }}        as total_invoice_line_amount  -- shipping_revenue term omitted while null per above; base term now net_sales_amount (LINEAMOUNT) rather than the re-derived formula

    -- Costs
    -- standard_cost_* is the purchase price (FACT_PRODUCT_COST current STANDARD, the D365 purchase
    -- trade agreement price), an analysis value restated to the current price on every merge of
    -- the line. The COGS basis is moving_avg_cost_* (EDW-182, I6).
        , j.standard_cost_unit
        , j.QTY * j.standard_cost_unit                               as standard_cost_amount
        , {{ amount('try_divide(j.posted_cost_amount, j.posted_qty)') }}  as moving_avg_cost_unit  -- EDW-182: D365's posted cost per unit on the line's legs (cost / quantity of the legs, both signed alike). USD. NULL on free text lines and the 22 lines with no INVENTTRANSID; 0 on the non-merchandise items D365 carries at no cost.
        , {{ amount("case when j.posted_qty = -j.QTY then -j.posted_cost_amount else try_divide(j.posted_cost_amount, j.posted_qty) * j.QTY end") }} as moving_avg_cost_amount  -- EDW-182: D365's posted cost of the line's legs, -(COSTAMOUNTPOSTED + COSTAMOUNTADJUSTMENT) with the line's sign (negative on credit lines). The COGS basis (I6); as of posting, never restated to a later price. Where the legs' quantity is not the line's (32 lines, 475 units, Jul to Oct 2026: D365 re-split the legs and silver still holds the rows it replaced, so the legs read double), the unit cost x invoiced_qty, which is what the ledger carries; on every other line the two are the same number.
        , cast(null as decimal(19,4)) as landed_cost_unit  -- Phase 2 per spec
        , cast(null as decimal(19,4)) as landed_cost_amount  -- Phase 2 per spec
        , cast(null as decimal(19,4)) as freight_cost_amount  -- Phase 2 per spec
        , coalesce(j.cost_currency_code, 'USD')                      as cost_currency_code

    -- Currency
        , j.CURRENCYCODE                                             as transaction_currency_code
        , j.fx_rate_to_usd  -- EDW-169: posted rate from the invoice header (CustInvoiceJour.EXCHRATE / 100), 1 on USD
        , {{ amount('j.LINEAMOUNTMST') }}                             as net_sales_amount_usd  -- EDW-169: LINEAMOUNTMST, the line as booked in USD. Equals round(LINEAMOUNT x EXCHRATE / 100, 2) on every line since Jul 2023 (checked Oct 14 2026).

    -- Nimbly (EDW-169): per unit on the sales line x invoiced_qty, so they carry the line's
    -- sign (negative on credit lines). Wholesale is net less fee and commission, the basis of
    -- the Executive Summary model's Wholesale Revenue. Both fields are 0 on CAD lines today.
        , {{ amount('j.QTY * j.nimbly_fee_unit') }}                   as nimbly_fee_amount
        , {{ amount('j.QTY * j.nimbly_commission_unit') }}            as nimbly_commission_amount
        , {{ amount('j.LINEAMOUNT - j.QTY * (j.nimbly_fee_unit + j.nimbly_commission_unit)') }} as wholesale_amount
        , {{ amount('j.QTY * j.nimbly_fee_unit * j.fx_rate_to_usd') }} as nimbly_fee_amount_usd
        , {{ amount('j.QTY * j.nimbly_commission_unit * j.fx_rate_to_usd') }} as nimbly_commission_amount_usd
        , {{ amount('j.LINEAMOUNTMST - j.QTY * (j.nimbly_fee_unit + j.nimbly_commission_unit) * j.fx_rate_to_usd') }} as wholesale_amount_usd
    -- Custom print fee (EDW-169): informational, not taken off wholesale (the Executive Summary
    -- model's Wholesale Revenue does not take it off either).
        , {{ amount('j.custom_print_fee_share') }}                    as custom_print_fee_amount
        , {{ amount('j.custom_print_fee_share * j.fx_rate_to_usd') }} as custom_print_fee_amount_usd

    -- Order Context
    -- order_type removed (spec v1.3, EDW-59): it never read a SalesType; invoice_type and is_return_flag carry the distinctions.
        , case when nullif(j.SALESID, '') is null then 'Free Text' else 'Sales Order' end as invoice_type  -- EDW-59 (spec 4.9): Sales Order when the line has a SALESID, Free Text when it does not
        , case when j.QTY < 0 or j.LINEAMOUNT < 0 then true else false end as is_return_flag  -- EDW-59 (spec 4.3): negative quantity or negative revenue, so a free text credit with no negative quantity reads as a return
        , nullif(j.RETURNREASONCODEID, '')                           as return_reason_code
        , cast(null as string) as return_reason_description  -- Source once available: no reason-code description lookup identified
        , case
            when nullif(trim(j.PAYMENT), '') is null then null
            when upper(trim(j.PAYMENT)) in ('PREPAID', 'NET10', 'NET30', 'NET45', 'NET60') then upper(trim(j.PAYMENT))
            else 'UNKNOWN'
          end                                                        as payment_terms_code  -- EDW-59 (spec 4.11): CustInvoiceJour.PAYMENT upper-cased (PrePaid / Prepaid / PREPAID to PREPAID); blank to NULL; anything else UNKNOWN. Same rule as fact_orders_returns.
        , case when nullif(j.SALESID, '') is not null then nullif(trim(j.PAYMMODE), '') end as payment_mode_code  -- EDW-59 (spec 4.11): SalesTable.PAYMMODE of the originating order as sourced (CC-BT, Credit, RevPoints, Check, ACH); blank to NULL; NULL on free text lines. An attribute, never subtracted from revenue.
        , case
            when coalesce(j.INTERCOMPANYPOSTED, 0) = 1 or upper(trim(j.CUSTGROUP)) = 'INTERCO' then true
            else false
          end                                                        as is_intercompany_flag  -- EDW-59 (spec 4.10, O7): include with a flag, never a filter. CUSTGROUP is read from the invoice header (the group as posted), which agrees with the customer table on every Interco invoice (checked Oct 15 2026).

    -- B2B Context
        , nullif(j.PURCHASEORDER, '')                                as customer_purchase_order
        , cast(null as string) as b2b_account_number  -- Phase 2 per spec

    -- DSO / Loyalty
        , j.dso_flag_at_invoice                                      as is_dso_order_flag  -- EDW-59 (spec 4.13): DIM_CUSTOMER is_dso_member_flag on the version in effect at the invoice date (customer_dso CTE). Membership history starts with the first customer snapshot (Oct 14 2026); earlier invoices read that first version.
        , cast(null as decimal(18,4)) as loyalty_points_earned  -- Phase 2 per spec v1.2: source is FACT_LOYALTY_TRANSACTION (EDW-78, order-level earn event), allocated to lines pro-rata by net_sales_amount over qualifying lines on the order (spec 4.8); qualifying-spend scope (costume-only vs. all products) open with Marketing. Stays a typed NULL until FACT_LOYALTY_TRANSACTION exists.
        -- loyalty_points_redeemed retired per spec v1.2 (Revolution Rewards two-step Rev Cash model, adopted 2026-08-19): points convert to a certificate and are spent as tender, so there's no invoice-line redemption event to source. Certificate burn is a FACT_PAYMENT_TRANSACTION event instead -- column dropped, not left as a null scaffold.

    -- Audit
        , j.RECID                                                    as d365_invoice_rec_id
        , 'silver_d365_cust_invoice_trans + silver_d365_cust_invoice_jour' as record_source_table
        {% if is_incremental() %}
        , coalesce(j.existing_etl_insert_datetime, current_timestamp()) as etl_insert_datetime  -- EDW-59 / EDW-132: kept across merges (existing CTE), same as fact_orders_returns
        {% else %}
        , current_timestamp()                                        as etl_insert_datetime
        {% endif %}
        , current_timestamp()                                        as etl_update_datetime
        , j.MODIFIEDDATE                                             as etl_source_modified_datetime
        , sha2(concat_ws('||', j.INVOICEID, cast(j.LINENUM as string), 'D365', cast(j.QTY as string), cast(j.SALESPRICE as string)), 256) as row_hash

    -- EDW-184: true when the line's order is a replacement order (is_replacement_flag on
    -- fact_orders_returns), false on every other Sales Order line, NULL on free text lines. A
    -- property of the order, so it reads on every line of it; the sale lines are the ones that
    -- matter (BS-367 D8: report Sales Amount leaves them out and Return Amount takes them in, as the
    -- GL does). Appended after row_hash so a full refresh and the in-place column add give the same
    -- position. Not in row_hash: it does not change once the line is invoiced.
        , case when nullif(j.SALESID, '') is not null then j.is_replacement_order end as is_replacement_order_flag

    from joined j

)

select * from final