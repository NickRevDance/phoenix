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
        , l.LINEAMOUNT
        , l.CURRENCYCODE
        , l.SALESSTATUS
        , l.SHIPPINGDATEREQUESTED
        , l.RETURNARRIVALDATE
        , l.RETURNDISPOSITIONCODEID
        , l.RETURNSTATUS
        , l.INVENTTRANSIDRETURN
        , l.REVWEBSITEFEE  -- EDW-169: Nimbly website fee, per unit
        , l.REVCOMMISSION  -- EDW-169: Nimbly commission, per unit
        , l.REVNETCUSTOMPRINTFEE  -- EDW-169: custom print fee, a line amount
        , l.INVENTTRANSID  -- EDW-57: link to the invoice lines (unique on SalesLine)
        , l.REMAINSALESPHYSICAL  -- EDW-57: D365's remaining quantity to deliver, the open quantity
        , l.DLVMODE  -- EDW-57: delivery mode on the line (the header's is blank on most orders)
        , l.SHIPPINGDATECONFIRMED  -- EDW-57
        , l.REVESTIMATEDSHIPDATE  -- EDW-57: current estimated ship date
        , l.REVOGESTIMATEDSHIPDATE  -- EDW-57: original estimated ship date, the first date promised
        , l.MODIFIEDDATE

    from {{ ref('silver_d365_sales_line') }} l

    -- Both forward-demand (3) and return (4) lines belong in this fact --
    -- unlike FACT_ORDER_LINE, which filters to 3 only. See spec Section 4.9
    -- (combined orders-and-returns design) and README.
    where l.SALESTYPE in (3, 4)

    {% if is_incremental() %}
    and (
        l.MODIFIEDDATE > (select coalesce(max(etl_source_modified_datetime), timestamp('1900-01-01')) from {{ this }}) - interval 2 days
        -- EDW-134 self-heal: re-pull lines that still hold an Unknown product
        or cast(l.REC as bigint) in (select d365_sales_line_rec_id from {{ this }} where product_key = '-1')
        -- EDW-135 self-heal: re-pull lines that still hold a null or Unknown customer
        or cast(l.REC as bigint) in (select d365_sales_line_rec_id from {{ this }} where customer_key is null or customer_key = -1)
        -- EDW-58: re-pull return lines whose return order header changed inside the same lookback.
        -- Reason, RMA number, replacement and refund tender sit on the header, and the watermark is on the line.
        or (
            l.SALESTYPE = 4
            and l.SALESID in (
                select h.SALESID
                from {{ ref('silver_d365_sales_table') }} h
                where h.SALESTYPE = 4
                  and h.MODIFIEDDATE > (select coalesce(max(etl_source_modified_datetime), timestamp('1900-01-01')) from {{ this }}) - interval 2 days
            )
        )
    )
    {% endif %}

),

sales_table as (

    select

          st.SALESID
        , st.REC
        , st.CUSTACCOUNT
        , st.SALESORIGINID
        , st.PURCHORDERFORMNUM
        , st.CREATEDDATE
        , st.PAYMENT  -- EDW-57: payment terms
        -- EDW-58: return lifecycle columns. On a return row these come from the return order's own header.
        , st.RETURNITEMNUM
        , st.RETURNREASONCODEID
        , st.RETURNREPLACEMENTCREATED
        , st.RETURNREPLACEMENTID
        , st.PAYMMODE
        , st.RETURNDEADLINE

    from {{ ref('silver_d365_sales_table') }} st

),

-- D365's return-order extension table (McrReturnSalesTable), one row per
-- return sales order header, linked 1:1 to SalesTable via SALESTABLE =
-- SalesTable.REC. Carries the return-to-original-order linkage.
return_header as (

    select

          r.SALESTABLE
        , r.ORIGINALSALESID

    from {{ ref('silver_d365_mcr_return_sales_table') }} r

),

-- EDW-58: the sales orders that replace a return (spec 4.11): every order named in a
-- return header's RETURNREPLACEMENTID. Read from the full header table, so a sales line
-- gets its flag on any run. McrReturnSalesTable.ISEXCHANGE is not used: it also marks
-- 27 orders that no return points to (checked October 7, 2026).
replacement_order as (

    select distinct

          rt.RETURNREPLACEMENTID as SALESID

    from {{ ref('silver_d365_sales_table') }} rt
    where rt.SALESTYPE = 4
      and rt.RETURNREPLACEMENTCREATED = 1
      and nullif(rt.RETURNREPLACEMENTID, '') is not null

),

-- EDW-58: the original sales line behind a return line (spec Section 3), matched on
-- INVENTTRANSIDRETURN = INVENTTRANSID. Reads the full silver table, not the line CTE,
-- because an incremental run only holds the lookback window there. INVENTTRANSID is
-- unique on SalesLine, so this join cannot fan out.
original_line as (

    select

          ol.INVENTTRANSID
        , cast(ol.REC as bigint) as original_rec_id
        , ol.LINENUM as original_linenum

    from {{ ref('silver_d365_sales_line') }} ol
    where ol.SALESTYPE in (3, 4)
      and nullif(ol.INVENTTRANSID, '') is not null

),

-- EDW-57: shipped quantity and ship date on the invoice basis (spec 4.9, step 2a). Revolution
-- invoices at shipment, so the invoice lines on a sales line's INVENTTRANSID are its shipments.
-- INVENTTRANSID is unique on SalesLine, so the join to the line cannot fan out; no credit
-- invoice line carries a sales line's INVENTTRANSID (checked October 14, 2026). Posting an
-- invoice touches the sales line's MODIFIEDDATE, so the line watermark re-pulls it.
shipment as (

    select

          t.INVENTTRANSID
        , sum(t.QTY)                                         as invoiced_qty
        , min(case when t.QTY > 0 then t.INVOICEDATE end)    as first_invoice_date

    from {{ ref('silver_d365_cust_invoice_trans') }} t
    where nullif(t.INVENTTRANSID, '') is not null
      and t.INVENTTRANSID in (select l.INVENTTRANSID from line l where l.SALESTYPE = 3)
    group by t.INVENTTRANSID

),

-- EDW-58: reason category lookup (spec 7.8), one row per code plus the blank-code row.
return_reason_category as (

    select

          return_reason_code
        , return_reason_category

    from {{ ref('ref_return_reason_category') }}

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

-- ITEMID + INVENTDIMID resolved through D365's item-barcode table to a UPC,
-- hashed identically to DIM_PRODUCT's own product_key formula (same path
-- as FACT_ORDER_LINE/FACT_SALES_INVOICE). item_barcode's own InventDimID is
-- a reference-level dimension record, not the transactional one on
-- SalesLine, so it's resolved through silver_d365_inventory_dim to
-- size/color first, then matched on ITEMID + size + color -- 99.79%
-- resolution confirmed live vs. 98.16% under the prior
-- style+size+color-to-dim_product path.
product as (

    -- EDW-134: dim membership check for product_key resolution.
    select product_key
    from {{ ref('dim_product') }}
    where version_number = 1
      and product_key <> '-1'

),

barcode as (

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

    select

          customer_key
        , customer_id
        , customer_segment_key  -- EDW-59: Type 1 on dim_customer, so this is the customer's segment today

    from {{ ref('dim_customer') }}
    where version_number = 1
      and source_system = 'D365'

),

customer_dso as (

    -- EDW-59: the DSO flag on the DIM_CUSTOMER version in effect at the order date (the
    -- is_dso_order_flag catalog row). Same ranges as fact_sales_invoice: each version runs to the day
    -- before the next one starts, the first reaches back to 1900-01-01 and the last stays open.
    -- Contiguous by construction, so the join cannot fan out.
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

warehouse as (

    select

          warehouse_key
        , warehouse_id
        , d365_site_id

    from {{ ref('dim_warehouse') }}
    where version_number = 1  -- EDW-90 item 4: fact key resolution uses the latest version, not is_current_row

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

-- EDW-169: spot rate to USD at the order date. Orders carry no posted rate (SalesTable
-- FIXEDEXCHRATE is zero or blank on every CAD order line), so the D365 monthly spot table
-- is the source (EDW-94 interim, the same table fact_product_cost reads; REF_FX_RATE is
-- EDW-127). Ranges are rebuilt here from valid_from_date: each rate runs to the day before
-- the next one, the first starts at 1900-01-01 and the last stays open, so a gap or a date
-- before the first rate still finds the nearest rate. One row per currency and start date.
fx_rate as (

    select

          r.from_currency_code
        , r.fx_rate_to_usd
        , case
            when row_number() over (partition by r.from_currency_code order by r.valid_from_date) = 1
            then date'1900-01-01'
            else r.valid_from_date
          end                                                       as rate_start_date
        , coalesce(
              date_sub(lead(r.valid_from_date) over (partition by r.from_currency_code order by r.valid_from_date), 1)
            , date'9999-12-31'
          )                                                         as rate_end_date

    from (

        select

              x.from_currency_code
            , x.fx_rate_to_usd
            , x.valid_from_date
            , row_number() over (
                partition by x.from_currency_code, x.valid_from_date
                order by x.d365_modified_datetime desc
              ) as rn

        from {{ ref('silver_d365_exchange_rate') }} x
        where x.to_currency_code = 'USD'

    ) r
    where r.rn = 1

),

{% if is_incremental() %}
-- Preserves etl_insert_datetime across merges -- Type 1 overwrite means a
-- line's row is updated in place on every status/quantity change, and the
-- spec's own field catalog distinguishes insert (fixed) from update
-- (touched every change). Without this, a plain incremental merge would
-- reset etl_insert_datetime on every touched row.
existing as (

    -- EDW-59: also holds customer_segment_key once written (the segment at the time the line was
    -- inserted, the order-date proxy), while the line's customer is unchanged. A NULL is not held,
    -- so a headerless line on the -1 customer takes a segment once its customer resolves. A full
    -- refresh restates the segment to the customer's segment on the day of the refresh.
    select

          orders_returns_key
        , etl_insert_datetime
        , customer_key
        , customer_segment_key

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
        , l.LINEAMOUNT
        , l.CURRENCYCODE
        , l.SALESSTATUS
        , l.SHIPPINGDATEREQUESTED
        , l.RETURNARRIVALDATE
        , l.RETURNDISPOSITIONCODEID
        , l.RETURNSTATUS
        , l.MODIFIEDDATE
        , l.REMAINSALESPHYSICAL
        , l.DLVMODE                              -- EDW-57: the line's delivery mode (was the header's)
        , l.SHIPPINGDATECONFIRMED
        , l.REVESTIMATEDSHIPDATE
        , l.REVOGESTIMATEDSHIPDATE
        , sh.invoiced_qty                        -- EDW-57: NULL when the line has no invoice line
        , sh.first_invoice_date
        , coalesce(l.REVWEBSITEFEE, 0)            as nimbly_fee_unit
        , coalesce(l.REVCOMMISSION, 0)            as nimbly_commission_unit
        , coalesce(l.REVNETCUSTOMPRINTFEE, 0)     as custom_print_fee_line
        , case
            when l.CURRENCYCODE = 'USD' then cast(1 as decimal(19,8))
            else fx.fx_rate_to_usd
          end                                    as fx_rate_to_usd  -- EDW-169

        , st.CUSTACCOUNT
        , st.SALESORIGINID
        , st.PURCHORDERFORMNUM
        , st.CREATEDDATE                         as order_created_date
        , st.PAYMENT
        , st.RETURNITEMNUM
        , st.RETURNREASONCODEID
        , st.RETURNREPLACEMENTCREATED
        , st.RETURNREPLACEMENTID
        , st.PAYMMODE
        , st.RETURNDEADLINE

        , rh.ORIGINALSALESID
        , ol.original_rec_id
        , ol.original_linenum
        , ro.SALESID is not null                 as is_replacement_order
        , rrc.return_reason_category

        , d.INVENTLOCATIONID
        -- EDW-134: UPCs missing from dim_product resolve to Unknown ('-1'); UPC kept in unresolved_upc
        , coalesce(prod.product_key, '-1')   as product_key
        , case when prod.product_key is null then bar.ITEMBARCODE end as unresolved_upc
        , coalesce(cu.customer_key, cast(-1 as bigint)) as customer_key  -- EDW-135: headerless lines resolve to the dim_customer -1 member
        , cu.customer_segment_key                as current_customer_segment_key  -- EDW-59: NULL on the -1 customer
        , dso.is_dso_member_flag                 as dso_flag_at_order  -- EDW-59: NULL on the -1 customer
        , wh.warehouse_key
        , coalesce(sc.sales_channel_key, -1)     as sales_channel_key
        {% if is_incremental() %}
        , ex.etl_insert_datetime                 as existing_etl_insert_datetime
        , ex.customer_key                        as existing_customer_key
        , ex.customer_segment_key                as existing_customer_segment_key
        {% endif %}

    from line l

    left join sales_table st
        on l.SALESID = st.SALESID

    -- Only matches for is_return_flag = 1 rows (SALESTYPE = 4) -- a forward
    -- order line's SALESID never appears as a return header's SALESTABLE.
    left join return_header rh
        on st.REC = rh.SALESTABLE

    -- EDW-58: return rows only. The line link is blank on cancelled returns.
    left join original_line ol
        on l.SALESTYPE = 4
        and nullif(l.INVENTTRANSIDRETURN, '') = ol.INVENTTRANSID

    -- EDW-57: sales rows only. A return line's own credit invoice is not a shipment.
    left join shipment sh
        on l.SALESTYPE = 3
        and nullif(l.INVENTTRANSID, '') = sh.INVENTTRANSID

    -- EDW-58: sales rows only.
    left join replacement_order ro
        on l.SALESTYPE = 3
        and l.SALESID = ro.SALESID

    -- EDW-58: return rows only. A blank or missing code joins the blank-code row (Other).
    left join return_reason_category rrc
        on l.SALESTYPE = 4
        and coalesce(nullif(trim(st.RETURNREASONCODEID), ''), '') = rrc.return_reason_code

    left join inventory_dim d
        on l.INVENTDIMID = d.InventDimID

    left join barcode bar
        on l.ITEMID = bar.ITEMID
        and d.INVENTSIZEID = bar.INVENTSIZEID
        and d.INVENTCOLORID = bar.INVENTCOLORID
        and bar.rn = 1

    left join product prod
        on md5(concat_ws('|', bar.ITEMBARCODE)) = prod.product_key

    left join customer cu
        on st.CUSTACCOUNT = cu.customer_id

    -- EDW-59: the customer version in effect on the order date as the fact derives it (same
    -- placeholder bounds as order_date); the line's modified date where the order has no usable
    -- created date, as in the fx_rate join below.
    left join customer_dso dso
        on cu.customer_key = dso.customer_key
        and coalesce(
              case when st.CREATEDDATE > timestamp('1901-01-01') and st.CREATEDDATE < timestamp('2040-01-01')
                   then cast(st.CREATEDDATE as date) end
            , cast(l.MODIFIEDDATE as date)
          ) >= dso.range_start_date
        and coalesce(
              case when st.CREATEDDATE > timestamp('1901-01-01') and st.CREATEDDATE < timestamp('2040-01-01')
                   then cast(st.CREATEDDATE as date) end
            , cast(l.MODIFIEDDATE as date)
          ) < dso.range_end_date

    left join warehouse wh
        on d.INVENTLOCATIONID = wh.warehouse_id
        and d.inventsiteid = wh.d365_site_id

    left join sales_origin_map som
        on st.SALESORIGINID = som.sales_origin_id

    left join sales_channel sc
        on som.channel_code = sc.channel_code

    -- EDW-169: rate at the order date as the fact derives it (same placeholder bounds as
    -- order_date); the line's modified date where the order has no usable created date.
    left join fx_rate fx
        on l.CURRENCYCODE = fx.from_currency_code
        and l.CURRENCYCODE <> 'USD'
        and coalesce(
              case when st.CREATEDDATE > timestamp('1901-01-01') and st.CREATEDDATE < timestamp('2040-01-01')
                   then cast(st.CREATEDDATE as date) end
            , cast(l.MODIFIEDDATE as date)
          ) between fx.rate_start_date and fx.rate_end_date

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
        , cast(l.LINENUM as decimal(10,4))                            as order_line_number  -- DECIMAL(10,4) at source precision, not INT -- fractional LINENUM values and re-created lines make the line number non-unique/non-integer within an order (spec Section 3).
        , cast(l.REC as bigint)                                       as d365_sales_line_rec_id  -- Grain component / join key to FACT_ORDER_LINE, spec Section 6.
        , 'D365'                                                      as source_system
        , cast(null as string) as bigcommerce_order_id  -- Source once available: no confirmed field -- SalesTable.REVINTEGRATIONID is 78.5% populated but not confirmed to be BigCommerce-specific; SUNECOMMORDERID (0% populated) ruled out. Same gap as FACT_ORDER_LINE.
        , case
            when l.SALESTYPE = 4 then nullif(l.RETURNITEMNUM, '')
            when l.SALESTYPE = 3 and l.is_replacement_order then nullif(l.RETURNITEMNUM, '')
          end                                                         as rma_id  -- EDW-58: SalesTable.RETURNITEMNUM (RMA-nnnnnn) on return rows and on the sales rows of a replacement order, NULL otherwise (spec 4.3). Was the return header's record id.
        , case when l.SALESTYPE = 4 then l.ORIGINALSALESID end        as original_order_id  -- McrReturnSalesTable.ORIGINALSALESID, 89% populated on return headers (123,288 of 138,758) -- Open Decision 5, not fully resolved
        , case when l.SALESTYPE = 4 then l.original_rec_id end        as original_d365_sales_line_rec_id  -- EDW-58: RECID of the original sales line via INVENTTRANSIDRETURN (spec Section 3). NULL on cancelled returns and on sales rows.
        , case when l.SALESTYPE = 4 then cast(l.original_linenum as decimal(10,4)) end as original_order_line_number  -- EDW-58: LINENUM of the same original line. Display value; join on the rec id.
        , case when l.SALESTYPE = 4 and l.RETURNREPLACEMENTCREATED = 1 then nullif(l.RETURNREPLACEMENTID, '') end as replacement_order_id  -- EDW-58: the sales order that replaces this return (spec 4.11). NULL when the return is not an exchange.

    -- Dim FKs
        , case when l.order_created_date is not null and l.order_created_date > timestamp('1901-01-01') and l.order_created_date < timestamp('2040-01-01')
               then cast(date_format(l.order_created_date, 'yyyyMMdd') as int)
               else null end                                          as order_date_key
        , case when l.SHIPPINGDATEREQUESTED is not null and l.SHIPPINGDATEREQUESTED > timestamp('1901-01-01') and l.SHIPPINGDATEREQUESTED < timestamp('2040-01-01')
               then cast(date_format(l.SHIPPINGDATEREQUESTED, 'yyyyMMdd') as int)
               else null end                                          as requested_ship_date_key  -- Placeholder dates on/after 2040-01-01 or on/before 1901-01-01 null out with their key per spec 7.6 (152 rows live).
        , case when l.SHIPPINGDATECONFIRMED is not null and l.SHIPPINGDATECONFIRMED > timestamp('1901-01-01') and l.SHIPPINGDATECONFIRMED < timestamp('2040-01-01')
               then cast(date_format(l.SHIPPINGDATECONFIRMED, 'yyyyMMdd') as int)
               else null end                                          as confirmed_ship_date_key  -- EDW-57: SalesLine.SHIPPINGDATECONFIRMED, placeholder rule (spec 7.6). Sparse (spec 4.9).
        , case when l.SALESTYPE = 3 and l.first_invoice_date is not null
               then cast(date_format(l.first_invoice_date, 'yyyyMMdd') as int)
               else null end                                          as actual_ship_date_key  -- EDW-57: earliest invoice date on the line (invoice basis, spec 4.9).
        , case when l.SALESTYPE = 3 and l.REVESTIMATEDSHIPDATE is not null and l.REVESTIMATEDSHIPDATE > timestamp('1901-01-01') and l.REVESTIMATEDSHIPDATE < timestamp('2040-01-01')
               then cast(date_format(l.REVESTIMATEDSHIPDATE, 'yyyyMMdd') as int)
               else null end                                          as estimated_ship_date_key  -- EDW-57: DIM_DATE key on estimated_ship_date (the Executive Summary's open orders by ship date).
        , cast(null as int) as delivery_date_key  -- Phase 2 per spec
        , case when l.SALESTYPE = 4 and l.RETURNARRIVALDATE is not null and l.RETURNARRIVALDATE > timestamp('1901-01-01') and l.RETURNARRIVALDATE < timestamp('2040-01-01')
               then cast(date_format(l.RETURNARRIVALDATE, 'yyyyMMdd') as int)
               else null end                                          as return_date_key  -- Same placeholder rule as requested_ship_date_key (spec 7.6) -- 1901 floor paired with a 2040 ceiling (25,020 rows live sit below the floor; none currently sit above the ceiling).
        , case when l.SALESTYPE = 4 and l.order_created_date is not null and l.order_created_date > timestamp('1901-01-01') and l.order_created_date < timestamp('2040-01-01')
               then cast(date_format(l.order_created_date, 'yyyyMMdd') as int)
               else null end                                          as return_request_date_key  -- EDW-58: DIM_DATE key on return_request_date.
        , cast(null as int) as cancel_date_key  -- Source once available: no dedicated cancellation-date field found on SalesLine -- MODIFIEDDATE reflects the row's last change generally, not confirmed to be the cancellation event specifically
        , l.product_key
        , l.unresolved_upc
        , l.customer_key
    -- ship_to_customer_key removed (retired, spec v1.2 O8; EDW-59): ship-to geography replaces it once LogisticsPostalAddress is ingested.
        , l.sales_channel_key
        , l.warehouse_key
        , cast(-1 as bigint)                                          as employee_sales_hierarchy_key  -- Coalesced to the reserved -1 UNKNOWN member rather than left null (same as FACT_ORDER_LINE/FACT_SALES_INVOICE) -- no worker/sales-rep table found, shared gap until EDW-19.
        , cast(null as bigint) as campaign_key  -- Phase 2 per spec
    -- promotion_key removed (deprecated, spec v1.2 O1; EDW-59): promotion analysis routes through FACT_DISCOUNT_APPLICATION.
        {% if is_incremental() %}
        , case
            when l.existing_customer_key = l.customer_key
            then coalesce(l.existing_customer_segment_key, l.current_customer_segment_key)
            else l.current_customer_segment_key
          end                                                         as customer_segment_key
        {% else %}
        , l.current_customer_segment_key                              as customer_segment_key
        {% endif %}
        -- EDW-59: the customer's segment when the line is written, held after that (existing CTE).
        -- DIM_CUSTOMER_SEGMENT has no -1 member, so a line on the -1 customer reads NULL.

    -- Dates
        , case when l.order_created_date is not null and l.order_created_date > timestamp('1901-01-01') and l.order_created_date < timestamp('2040-01-01')
               then cast(l.order_created_date as date)
               else null end                                          as order_date
        , case when l.SHIPPINGDATEREQUESTED is not null and l.SHIPPINGDATEREQUESTED > timestamp('1901-01-01') and l.SHIPPINGDATEREQUESTED < timestamp('2040-01-01')
               then cast(l.SHIPPINGDATEREQUESTED as date)
               else null end                                          as requested_ship_date
        , case when l.SHIPPINGDATECONFIRMED is not null and l.SHIPPINGDATECONFIRMED > timestamp('1901-01-01') and l.SHIPPINGDATECONFIRMED < timestamp('2040-01-01')
               then cast(l.SHIPPINGDATECONFIRMED as date)
               else null end                                          as confirmed_ship_date  -- EDW-57: see confirmed_ship_date_key
        , case when l.SALESTYPE = 3 then cast(l.first_invoice_date as date) end as actual_ship_date  -- EDW-57: earliest invoice date on INVENTTRANSID (invoice basis, spec 4.9). NULL unshipped and on return rows; re-sources to the packing slip when it lands (EDW-55).
        , case when l.SALESTYPE = 3 and l.REVESTIMATEDSHIPDATE is not null and l.REVESTIMATEDSHIPDATE > timestamp('1901-01-01') and l.REVESTIMATEDSHIPDATE < timestamp('2040-01-01')
               then cast(l.REVESTIMATEDSHIPDATE as date)
               else null end                                          as estimated_ship_date  -- EDW-57: SalesLine.REVESTIMATEDSHIPDATE, the current estimate. The 1900 and 2040 placeholders read NULL here and are kept in estimated_ship_date_status.
        , case when l.SALESTYPE = 3 and l.REVOGESTIMATEDSHIPDATE is not null and l.REVOGESTIMATEDSHIPDATE > timestamp('1901-01-01') and l.REVOGESTIMATEDSHIPDATE < timestamp('2040-01-01')
               then cast(l.REVOGESTIMATEDSHIPDATE as date)
               else null end                                          as original_estimated_ship_date  -- EDW-57: SalesLine.REVOGESTIMATEDSHIPDATE, the first date promised. The on-time target in V_METRICS_ORDER_FULFILLMENT.
        , cast(null as date) as delivery_date  -- Phase 2 per spec
        , cast(null as date) as cancel_date  -- Source once available: see cancel_date_key
        , case when l.SALESTYPE = 4 and l.RETURNARRIVALDATE is not null and l.RETURNARRIVALDATE > timestamp('1901-01-01') and l.RETURNARRIVALDATE < timestamp('2040-01-01')
               then cast(l.RETURNARRIVALDATE as date)
               else null end                                          as return_date
        , case when l.SALESTYPE = 4 and l.order_created_date is not null and l.order_created_date > timestamp('1901-01-01') and l.order_created_date < timestamp('2040-01-01')
               then cast(l.order_created_date as date)
               else null end                                          as return_request_date  -- EDW-58: the return order's CREATEDDATE on return rows (equals order_date there; kept so return metrics read one column).
        , case when l.SALESTYPE = 4 and l.RETURNDEADLINE is not null and l.RETURNDEADLINE > timestamp('1901-01-01') and l.RETURNDEADLINE < timestamp('2040-01-01')
               then cast(l.RETURNDEADLINE as date)
               else null end                                          as return_deadline  -- EDW-58: SalesTable.RETURNDEADLINE on return rows, placeholder rule (spec 7.6).

    -- Status
    -- D365 SalesStatus enum: 0=None, 1=Backorder, 2=Delivered, 3=Invoiced,
    -- 4=Canceled. Mapped to the spec's Phase 1 conformed status set per
    -- Business Rule 7.1. Backorder -> Confirmed and Invoiced -> Shipped (no
    -- separate shipped signal exists in this BYOD extract; invoicing is the
    -- closest available proxy). Picked/Packed have no source at all.
        , case
            when l.SALESTYPE = 4 then 'Returned'
            when l.SALESSTATUS = 0 then 'Open'
            when l.SALESSTATUS = 1 then 'Confirmed'
            when l.SALESSTATUS = 2 then 'Delivered'
            when l.SALESSTATUS = 3 then 'Shipped'
            when l.SALESSTATUS = 4 then 'Cancelled'
            else cast(l.SALESSTATUS as string)
          end                                                         as order_line_status
        , case
            when l.SALESTYPE = 3 then 'Sales Order'
            when l.SALESTYPE = 4 then 'Return Order'
            else 'Unknown'
          end                                                         as order_type  -- D365 SalesType label mapping per spec 7.7/C6 -- 3 = Sales Order, 4 = Return Order, else Unknown. is_return_flag below still derives from the raw SALESTYPE value directly.
        , case when l.SALESTYPE = 4 then
            case l.RETURNSTATUS
                when 1 then 'Awaiting'
                when 2 then 'Registered'
                when 4 then 'Received'
                when 5 then 'Invoiced'
                when 6 then 'Cancelled'
                else cast(l.RETURNSTATUS as string)
            end
          end                                                         as return_status  -- EDW-58: SalesLine.RETURNSTATUS on return rows, labels per spec 7.9. Any other value is kept as its number and shows on the accepted-values test.
        , case when l.SALESTYPE = 4 then true else false end          as is_return_flag
        , case when l.SALESSTATUS = 4 or l.REVQTYCANCELLED > 0 then true else false end as is_cancelled_flag
        , case when l.SALESSTATUS = 1 then true else false end        as is_backordered_flag  -- Reflects SalesStatus = Backorder as of the current ETL run, not true backorder history -- same current-state caveat as FACT_ORDER_LINE's order_line_status_at_creation
        , case when l.SALESTYPE = 3 then
            coalesce(l.invoiced_qty, 0) > 0 and coalesce(l.invoiced_qty, 0) < l.QTYORDERED - coalesce(l.REVQTYCANCELLED, 0)
          end                                                         as is_partial_ship_flag  -- EDW-57: some but not all of the ordered less cancelled quantity shipped (spec 7.4). Open partial lines and lines closed short both read true. NULL on return rows.
        , case when l.SALESTYPE = 3 then
            case
                when l.REVESTIMATEDSHIPDATE >= timestamp('2040-01-01') then 'Awaiting Release'
                when l.REVESTIMATEDSHIPDATE > timestamp('1901-01-01') then 'Assigned'
                else 'Not Assigned'
            end
          end                                                         as estimated_ship_date_status  -- EDW-57: what the estimated ship date placeholder means. D365 writes 1900-01-01 until a date is assigned and 2040-01-01 on branded lines held for release. NULL on return rows.
        , case when l.SALESTYPE = 3 then l.is_replacement_order end   as is_replacement_flag  -- EDW-58: sales rows, true when the order is named in a return header's RETURNREPLACEMENTID (spec 4.11). NULL on return rows.
        , case when l.SALESTYPE = 4 then coalesce(l.RETURNREPLACEMENTCREATED = 1, false) end as is_exchange_flag  -- EDW-58: return rows, true when the return header has RETURNREPLACEMENTCREATED = 1 (spec 4.11). NULL on sales rows.
        , l.dso_flag_at_order                                         as is_dso_order_flag  -- EDW-59: DIM_CUSTOMER is_dso_member_flag on the version in effect at the order date (customer_dso CTE). Membership history starts with the first customer snapshot (Oct 14 2026); earlier orders read that first version. NULL on the -1 customer.

    -- Quantities
        , l.QTYORDERED                                                 as ordered_qty
        , cast(null as decimal(18,4)) as confirmed_qty  -- Source once available: no confirmed-availability quantity field found separate from QTYORDERED
        , cast(null as decimal(18,4)) as picked_qty  -- Phase 2 per spec
        , case when l.SALESTYPE = 3 then {{ amount('coalesce(l.invoiced_qty, 0)') }} end as shipped_qty  -- EDW-57: sum of CustInvoiceTrans.QTY on INVENTTRANSID (invoice basis, spec 4.9). 0 when the line has no invoice line; NULL on return rows. SALESDELIVERNOW / INVENTDELIVERNOW are 0 on every row and are not used.
        , cast(null as decimal(18,4)) as delivered_qty  -- Phase 2 per spec
        , l.REVQTYCANCELLED                                            as cancelled_qty
        , case when l.SALESTYPE = 4 then abs(l.QTYORDERED) end        as returned_qty  -- Return lines carry QTYORDERED negative in live data -- abs() to express as a positive returned quantity per spec
    -- backordered_qty removed (retired on EDW-57, dropped on EDW-59): the backordered quantity is open_qty. D365's remaining quantity is above 0 only on Backorder lines, so a separate column would equal open_qty on every row.
        , case when l.SALESTYPE = 3 then {{ amount('l.REMAINSALESPHYSICAL') }} end as open_qty  -- EDW-57: SalesLine.REMAINSALESPHYSICAL, D365's remaining quantity to deliver. Equals ordered - shipped - cancelled on every open line; 0 on closed lines, where that subtraction can leave a remainder (lines closed short) or go negative (a cancel quantity on fully invoiced lines). NULL on return rows.
        , coalesce(nullif(l.SALESUNIT, ''), 'ea')                     as qty_uom

    -- Amounts
        , l.SALESPRICE                                                 as unit_price
        , l.QTYORDERED * l.SALESPRICE                                  as line_amount
        , {{ amount('l.QTYORDERED * l.LINEDISC') }}                    as line_discount_amount  -- LINEDISC is a per-unit amount, not a line total, per spec 7.5 (same as FACT_ORDER_LINE/FACT_SALES_INVOICE).
        , {{ amount('l.LINEAMOUNT') }}                                 as net_line_amount  -- Sourced from SalesLine.LINEAMOUNT directly (source truth) instead of re-derived from QTYORDERED * SALESPRICE - LINEDISC -- the derived formula only ties on 2,676,078 of 2,838,957 lines (94.3%) live.
        , case when l.SALESTYPE = 4 then {{ amount('abs(l.LINEAMOUNT)') }} end as return_amount  -- Net of discount per spec 7.5: abs(LINEAMOUNT) on return lines, not abs(QTYORDERED) * SALESPRICE, which ignores discount entirely.
        , l.CURRENCYCODE                                               as transaction_currency_code
        , l.fx_rate_to_usd  -- EDW-169: spot rate at the order date (fx_rate CTE), 1 on USD
        , {{ amount('l.LINEAMOUNT * l.fx_rate_to_usd') }}             as net_line_amount_usd  -- EDW-169

    -- Nimbly (EDW-169): per unit on the sales line x ordered_qty, so they carry the line's
    -- sign (negative on return lines). Wholesale is net less fee and commission, the basis of
    -- the Executive Summary model's Order Amount. Both fields are 0 on CAD lines today.
        , {{ amount('l.QTYORDERED * l.nimbly_fee_unit') }}            as nimbly_fee_amount
        , {{ amount('l.QTYORDERED * l.nimbly_commission_unit') }}     as nimbly_commission_amount
        , {{ amount('l.LINEAMOUNT - l.QTYORDERED * (l.nimbly_fee_unit + l.nimbly_commission_unit)') }} as wholesale_line_amount
        , {{ amount('l.QTYORDERED * l.nimbly_fee_unit * l.fx_rate_to_usd') }} as nimbly_fee_amount_usd
        , {{ amount('l.QTYORDERED * l.nimbly_commission_unit * l.fx_rate_to_usd') }} as nimbly_commission_amount_usd
        , {{ amount('(l.LINEAMOUNT - l.QTYORDERED * (l.nimbly_fee_unit + l.nimbly_commission_unit)) * l.fx_rate_to_usd') }} as wholesale_line_amount_usd
    -- Custom print fee (EDW-169): a line amount as stored on the sales line. Informational, not
    -- taken off wholesale.
        , {{ amount('l.custom_print_fee_line') }}                     as custom_print_fee_amount
        , {{ amount('l.custom_print_fee_line * l.fx_rate_to_usd') }}  as custom_print_fee_amount_usd
    -- Open order value (EDW-57): the line's net and wholesale amounts prorated by open over
    -- ordered quantity, in transaction currency and USD. open_wholesale_amount_usd is the
    -- Executive Summary's Open Orders Amount. 0 when nothing is open; NULL on return rows.
        , case when l.SALESTYPE = 3 then {{ amount('coalesce(l.LINEAMOUNT * l.REMAINSALESPHYSICAL / nullif(l.QTYORDERED, 0), 0)') }} end as open_line_amount
        , case when l.SALESTYPE = 3 then {{ amount('coalesce(l.LINEAMOUNT * l.REMAINSALESPHYSICAL / nullif(l.QTYORDERED, 0), 0) * l.fx_rate_to_usd') }} end as open_line_amount_usd
        , case when l.SALESTYPE = 3 then {{ amount('coalesce((l.LINEAMOUNT - l.QTYORDERED * (l.nimbly_fee_unit + l.nimbly_commission_unit)) * l.REMAINSALESPHYSICAL / nullif(l.QTYORDERED, 0), 0)') }} end as open_wholesale_amount
        , case when l.SALESTYPE = 3 then {{ amount('coalesce((l.LINEAMOUNT - l.QTYORDERED * (l.nimbly_fee_unit + l.nimbly_commission_unit)) * l.REMAINSALESPHYSICAL / nullif(l.QTYORDERED, 0), 0) * l.fx_rate_to_usd') }} end as open_wholesale_amount_usd

    -- Returns
        , case when l.SALESTYPE = 4 then nullif(trim(l.RETURNREASONCODEID), '') end as return_reason_code  -- EDW-58: SalesTable.RETURNREASONCODEID on return rows, as sourced. NULL when blank (spec 7.8).
        , cast(null as string) as return_reason_description  -- Source once available: the D365 ReturnReasonCode entity (EDW-55)
        , case when l.SALESTYPE = 4 then coalesce(l.return_reason_category, 'Other') end as return_reason_category  -- EDW-58: from ref_return_reason_category (spec 7.8). A blank code and a code not yet in the seed both read Other, so every return row has a category.
        , case when l.SALESTYPE = 4 then nullif(trim(l.RETURNDISPOSITIONCODEID), '') end as return_disposition_code  -- EDW-58: SalesLine.RETURNDISPOSITIONCODEID on return rows. NULL when blank (the return is cancelled or still awaited).
        , case when l.SALESTYPE = 4 then
            case nullif(trim(l.RETURNDISPOSITIONCODEID), '')
                when '10' then 'CREDIT'
                when '20' then 'REPLACE_SCRAP'
                when '30' then 'CREDIT_INSPECT'
                else case when nullif(trim(l.RETURNDISPOSITIONCODEID), '') is not null then 'UNKNOWN' end
            end
          end                                                         as return_disposition  -- EDW-58: label for return_disposition_code (spec 4.6). UNKNOWN for any other code; NULL when the code is blank.
        , cast(null as string) as return_condition_code  -- Phase 2 per spec: no D365 source, Salesforce RMA side (FACT_RMA)
        , case when l.SALESTYPE = 4 then
            case
                when l.RETURNREPLACEMENTCREATED = 1 then 'Exchange'
                when upper(trim(l.PAYMMODE)) in ('CC-BT', 'CHECK', 'ACH') then 'Original Payment'
                when upper(trim(l.PAYMMODE)) = 'CREDIT' then 'Store Credit'
                when upper(trim(l.PAYMMODE)) = 'REVPOINTS' then 'Loyalty Points'
                else 'Unknown'
            end
          end                                                         as refund_method  -- EDW-58: the return order's PAYMMODE decoded, with Exchange taking precedence (spec 4.11). PAYMMODE itself is payment_mode_code (EDW-57).

    -- Payment (EDW-57, spec 4.13 and 7.12): from the order header, on sales and return rows.
        , case
            when nullif(trim(l.PAYMENT), '') is null then null
            when upper(trim(l.PAYMENT)) in ('PREPAID', 'NET10', 'NET30', 'NET45', 'NET60') then upper(trim(l.PAYMENT))
            else 'UNKNOWN'
          end                                                         as payment_terms_code  -- EDW-57: SalesTable.PAYMENT upper-cased (PrePaid / Prepaid / PREPAID to PREPAID); blank to NULL; anything else UNKNOWN. Same domain as FACT_SALES_INVOICE.
        , nullif(trim(l.PAYMMODE), '')                                 as payment_mode_code  -- EDW-57: SalesTable.PAYMMODE as sourced (CC-BT, Credit, RevPoints, Check, ACH); blank to NULL.

    -- B2B
        , nullif(l.PURCHORDERFORMNUM, '')                              as customer_purchase_order
        , cast(null as string) as b2b_account_number  -- Phase 2 per spec -- master is dim_customer per spec Section 6

    -- Fulfillment
        , nullif(trim(l.DLVMODE), '')                                  as shipping_method  -- EDW-57: SalesLine.DLVMODE as sourced (spec Section 10). Read the header's DLVMODE before, which is blank on most orders.
        , case
            when nullif(trim(l.DLVMODE), '') is null then null
            else case upper(split(trim(l.DLVMODE), '-')[0])
                when 'UPS'        then 'UPS'
                when 'FEDEX'      then 'FEDEX'
                when 'USPS'       then 'USPS'
                when 'FRONT'      then 'FRONTIER'
                when 'IDS'        then 'IDS'
                when 'SHIPTODESK' then 'SHIP_TO_DESK'
                else 'UNKNOWN'
            end
          end                                                         as carrier_code  -- EDW-57: the DLVMODE token before the first hyphen, upper-cased (spec 7.11). Frontier is Front-fntr in D365. SHIP_TO_DESK is a delivery method kept in the domain. The raw value stays in shipping_method.
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
        , sha2(concat_ws('||', l.SALESID, cast(l.LINENUM as string), 'D365', cast(l.SALESTYPE as string), cast(l.QTYORDERED as string), cast(l.REVQTYCANCELLED as string), coalesce(cast(l.SALESSTATUS as string), '')
            -- EDW-58: return_status, return_disposition_code, is_exchange_flag, replacement_order_id (spec 4.2)
            , coalesce(case when l.SALESTYPE = 4 then cast(l.RETURNSTATUS as string) end, '')
            , coalesce(case when l.SALESTYPE = 4 then nullif(trim(l.RETURNDISPOSITIONCODEID), '') end, '')
            , coalesce(case when l.SALESTYPE = 4 then cast(coalesce(l.RETURNREPLACEMENTCREATED = 1, false) as string) end, '')
            , coalesce(case when l.SALESTYPE = 4 and l.RETURNREPLACEMENTCREATED = 1 then nullif(l.RETURNREPLACEMENTID, '') end, '')
            -- EDW-57: shipped_qty, open_qty, actual_ship_date and the two estimated ship dates (spec 4.2)
            , coalesce(case when l.SALESTYPE = 3 then cast(coalesce(l.invoiced_qty, 0) as string) end, '')
            , coalesce(case when l.SALESTYPE = 3 then cast(l.REMAINSALESPHYSICAL as string) end, '')
            , coalesce(case when l.SALESTYPE = 3 then cast(cast(l.first_invoice_date as date) as string) end, '')
            , coalesce(case when l.SALESTYPE = 3 then cast(cast(l.REVESTIMATEDSHIPDATE as date) as string) end, '')
            , coalesce(case when l.SALESTYPE = 3 then cast(cast(l.REVOGESTIMATEDSHIPDATE as date) as string) end, '')
          ), 256) as row_hash

    from joined l

)

select * from final