{{ config(
    materialized = 'incremental',
    unique_key = 'order_line_key',
    incremental_strategy = 'merge',
    on_schema_change = 'sync_all_columns',
    merge_update_columns = [
        'product_key', 'unresolved_upc',
        'customer_key', 'customer_segment_key', 'is_dso_order_flag',
        'order_date', 'order_date_key', 'sales_channel_key', 'source_sales_origin_id',
        'customer_purchase_order', 'shipping_method', 'payment_terms_code', 'payment_mode_code',
        'is_source_deleted_flag'
    ],
    post_hook = [
        "{{ sync_source_deleted_flag('order_line_key', ref('silver_d365_sales_line'), 'REC', key_salt='D365') }}"
    ]
) }}

-- EDW-56: insert-only (spec 4.1). A matched row updates only the self-heal columns above, and each of
-- those holds its first resolved value (existing CTE), so business columns and etl_insert_datetime never move.
-- EDW-177: a line deleted in D365 stays on the fact (spec Open Decision 9) with is_source_deleted_flag = true.
-- The flag is the one column that follows the source after insert; the post-hook keeps it in step with
-- silver on every row, since a delete doesn't move MODIFIEDDATE.

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
        , l.LINEAMOUNT
        , l.CURRENCYCODE
        , l.SALESSTATUS
        , l.SHIPPINGDATEREQUESTED
        , l.MODIFIEDDATE
        , coalesce(l.is_deleted, 0) = 1 as is_source_deleted  -- EDW-177

    from {{ ref('silver_d365_sales_line') }} l

    -- Business rule 7.2 (spec): forward-demand lines only. Only SALESTYPE 3/4
    -- exist in live data at all; 4 correlates 100% with a non-zero RETURNSTATUS
    -- (confirmed live 2026-09-11: all 215,909 SALESTYPE=4 lines carry
    -- RETURNSTATUS in {1,2,4,5,6}, all 2,588,292 SALESTYPE=3 lines carry
    -- RETURNSTATUS=0) -- treated as the Return population per spec Section 3,
    -- excluded here. EDW-21 v1.1 (2026-10-07): the fact carries no
    -- order_type column (spec 4.3 / 7.2, decision C7) -- SALESTYPE = 3 is
    -- the only value this fact admits, so it is a filter, not an attribute.
    where l.SALESTYPE = 3

    -- Grace period so the SalesTable header has time to land
    and l.MODIFIEDDATE <= current_timestamp() - interval 30 minutes

    {% if is_incremental() %}
    and (
        l.MODIFIEDDATE > (select coalesce(max(etl_source_modified_datetime), timestamp('1900-01-01')) from {{ this }}) - interval {{ var('order_line_lookback_days', 2) }} days
        -- EDW-134 self-heal: re-pull lines that still hold an Unknown product
        or xxhash64(l.REC, 'D365') in (select order_line_key from {{ this }} where product_key = '-1')
        -- EDW-135 self-heal: re-pull lines that still hold a null or Unknown customer
        or xxhash64(l.REC, 'D365') in (select order_line_key from {{ this }} where customer_key is null or customer_key = -1)
    )
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
        , st.PAYMENT  -- EDW-56: payment terms
        , st.PAYMMODE  -- EDW-56: tender

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

    -- EDW-134: dim membership check for product_key resolution.
    select product_key
    from {{ ref('dim_product') }}
    where version_number = 1
      and product_key <> '-1'

),

barcode as (

    -- 2026-09-16 fix (Chris review, same pattern as EDW-23/fact_sales_invoice
    -- and fact_product_price's EDW-20 rebuild): ITEMID + INVENTDIMID resolve
    -- through D365's item-barcode table to a UPC, hashed identically to
    -- DIM_PRODUCT's own product_key formula (md5(ifnull(upc,'0'))) so the two
    -- line up without a second lookup table. Replaces the prior
    -- style+size+color join to dim_product, which is the same join shape that
    -- left ~10% of rows with no product_key on the inventory snapshot fact.
    -- item_barcode's own InventDimID is a reference-level dimension record,
    -- not the transactional one on SalesLine/CustInvoiceTrans -- confirmed
    -- live 2026-09-16 that a direct InventDimID join matches 0 rows even
    -- though every ITEMID overlaps. Resolved through silver_d365_inventory_dim
    -- to size/color instead, then matched on ITEMID + size + color against
    -- the transactional line's own size/color (same inventory_dim CTE this
    -- model already joins for warehouse) -- 99.77% resolution confirmed live,
    -- vs. 97.95% via the old style+size+color-to-dim_product path.
    -- Most-recently-modified barcode wins when more than one exists for the
    -- same item + size + color (same dedupe convention used everywhere else
    -- in this project).
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

          c.customer_key
        , c.customer_id
        , c.customer_segment_key  -- EDW-56: Type 1 on dim_customer, so this is the customer's segment today

    from {{ ref('dim_customer') }} c
    where c.version_number = 1
      and c.source_system = 'D365'

),

customer_dso as (

    -- EDW-56: the DSO flag on the DIM_CUSTOMER version in effect at the order date, same ranges as
    -- fact_orders_returns: each version runs to the day before the next starts, the first reaches
    -- back to 1900-01-01 and the last stays open, so the join cannot fan out.
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
    where version_number = 1  -- EDW-90 item 4: fact key resolution resolves against the latest version, not is_current_row

),

sales_origin_map as (

    -- BigComUS -> BigComUSA reseed landed on main 2026-09-11 (commit
    -- 8fede99); REF_SALES_ORIGIN_MAP rebuilt to spec v1.1 2026-09-16
    -- (EDW-16) -- Nimbly origins now map to their own NIMBLY_S2C/
    -- NIMBLY_S2S channel rows instead of rolling into B2B_DIRECT.
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

existing as (

    -- EDW-56: values already on the fact, held on later merges (see the held columns in final).
    -- Empty on a full refresh, so every row resolves fresh.
    select

          t.order_line_key
        , t.product_key
        , t.unresolved_upc
        , t.customer_key
        , t.customer_segment_key
        , t.is_dso_order_flag
        , t.order_date
        , t.order_date_key
        , t.sales_channel_key
        , t.source_sales_origin_id
        , t.customer_purchase_order
        , t.shipping_method
        , t.payment_terms_code
        , t.payment_mode_code

    {% if is_incremental() %}
    from {{ this }} t
    {% else %}
    from (
        select
              cast(null as bigint)  as order_line_key
            , cast(null as string)  as product_key
            , cast(null as string)  as unresolved_upc
            , cast(null as bigint)  as customer_key
            , cast(null as bigint)  as customer_segment_key
            , cast(null as boolean) as is_dso_order_flag
            , cast(null as date)    as order_date
            , cast(null as int)     as order_date_key
            , cast(null as bigint)  as sales_channel_key
            , cast(null as string)  as source_sales_origin_id
            , cast(null as string)  as customer_purchase_order
            , cast(null as string)  as shipping_method
            , cast(null as string)  as payment_terms_code
            , cast(null as string)  as payment_mode_code
    ) t
    where 1 = 0
    {% endif %}

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
        , l.LINEAMOUNT
        , l.CURRENCYCODE
        , l.SALESSTATUS
        , l.SHIPPINGDATEREQUESTED
        , l.MODIFIEDDATE
        , l.is_source_deleted

        , st.CUSTACCOUNT
        , st.SALESORIGINID
        , st.DLVMODE
        , st.PURCHORDERFORMNUM
        , st.CREATEDDATE                         as order_created_date
        , from_utc_timestamp(st.CREATEDDATE, 'America/Chicago') as order_created_datetime_ct  -- EDW-56: Central clock, same basis as fact_orders_returns (EDW-184)
        , st.PAYMENT
        , st.PAYMMODE

        , d.INVENTLOCATIONID
        -- EDW-134: UPCs missing from dim_product resolve to Unknown ('-1'); UPC kept in unresolved_upc
        , coalesce(prod.product_key, '-1')   as product_key
        , case when prod.product_key is null then bar.ITEMBARCODE end as unresolved_upc
        , coalesce(cu.customer_key, cast(-1 as bigint)) as customer_key  -- EDW-135: headerless lines resolve to the dim_customer -1 member
        , cu.customer_segment_key                as current_customer_segment_key  -- EDW-56: NULL on the -1 customer
        , dso.is_dso_member_flag                 as dso_flag_at_order  -- EDW-56: NULL on the -1 customer
        , wh.warehouse_key
        , coalesce(sc.sales_channel_key, -1)      as sales_channel_key  -- 2026-09-16 fix (Chris review, same as EDW-23/fact_sales_invoice v1.2): sales_channel_key is never NULL -- unmapped/blank origins resolve to dim_sales_channel's reserved -1 UNKNOWN member.

    from line l

    left join sales_table st
        on l.SALESID = st.SALESID

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

    left join customer_dso dso
        on cu.customer_key = dso.customer_key
        and coalesce(cast(from_utc_timestamp(st.CREATEDDATE, 'America/Chicago') as date), cast(l.MODIFIEDDATE as date)) >= dso.range_start_date
        and coalesce(cast(from_utc_timestamp(st.CREATEDDATE, 'America/Chicago') as date), cast(l.MODIFIEDDATE as date)) < dso.range_end_date

    left join warehouse wh
        on d.INVENTLOCATIONID = wh.warehouse_id
        and d.inventsiteid = wh.d365_site_id

    left join sales_origin_map som
        on st.SALESORIGINID = som.sales_origin_id

    left join sales_channel sc
        on som.channel_code = sc.channel_code

),

held as (

    -- EDW-56: three hold rules, one per self-heal family. A product holds once it resolves (EDW-134),
    -- a customer and its segment/DSO values hold once the customer resolves (EDW-135), and the
    -- header columns hold once a header has been seen, so a later header delete can't blank them.
    select

          j.*
        , ex.order_line_key is not null and ex.product_key <> '-1'                as is_product_held
        , ex.order_line_key is not null and ex.customer_key <> -1                 as is_customer_held
        , ex.order_line_key is not null and ex.order_date is not null             as is_header_held
        , ex.product_key                         as existing_product_key
        , ex.unresolved_upc                      as existing_unresolved_upc
        , ex.customer_key                        as existing_customer_key
        , ex.customer_segment_key                as existing_customer_segment_key
        , ex.is_dso_order_flag                   as existing_is_dso_order_flag
        , ex.order_date                          as existing_order_date
        , ex.order_date_key                      as existing_order_date_key
        , ex.sales_channel_key                   as existing_sales_channel_key
        , ex.source_sales_origin_id              as existing_source_sales_origin_id
        , ex.customer_purchase_order             as existing_customer_purchase_order
        , ex.shipping_method                     as existing_shipping_method
        , ex.payment_terms_code                  as existing_payment_terms_code
        , ex.payment_mode_code                   as existing_payment_mode_code

    from joined j

    left join existing ex
        on xxhash64(j.REC, 'D365') = ex.order_line_key

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
        , cast(l.LINENUM as decimal(10,4))                           as order_line_number  -- EDW-21 v1.1 (2026-10-07): DECIMAL(10,4), not INT -- fractional LINENUM values and re-created lines make the line number non-unique/non-integer within an order (spec Section 3). Display and sort attribute, not the grain. Same cast as FACT_ORDERS_RETURNS.
        , cast(l.REC as bigint)                                      as d365_sales_line_rec_id  -- EDW-21 v1.1 (2026-10-07): SalesLine RECID. Grain component (order_id + d365_sales_line_rec_id) and the join key to FACT_ORDERS_RETURNS, spec Section 3 / 6.
        , 'D365'                                                     as source_system
        , cast(null as string) as bigcommerce_order_id  -- Source once available: no confirmed field -- SalesTable.REVINTEGRATIONID is 78.5% populated but not confirmed to be BigCommerce-specific; SUNECOMMORDERID (0% populated) ruled out

    -- Dim FKs
        , case when l.is_header_held then l.existing_order_date_key
               else coalesce(cast(date_format(l.order_created_datetime_ct, 'yyyyMMdd') as int), -1)
          end                                                         as order_date_key  -- EDW-56 (spec 7.11): a line with no order header goes to the DIM_DATE -1 member; order_date stays NULL
        , case when l.SHIPPINGDATEREQUESTED is not null and l.SHIPPINGDATEREQUESTED > timestamp('1901-01-01') and l.SHIPPINGDATEREQUESTED < timestamp('2040-01-01')
               then cast(date_format(l.SHIPPINGDATEREQUESTED, 'yyyyMMdd') as int)
               else null end                                          as requested_ship_date_key  -- EDW-21 v1.1 (2026-10-07): placeholder dates on/after 2040-01-01 or on/before 1901-01-01 null out with their key (spec 4.7 / 7.8). Same rule as FACT_ORDERS_RETURNS.
        , case when l.is_product_held then l.existing_product_key else l.product_key end         as product_key
        , case when l.is_product_held then l.existing_unresolved_upc else l.unresolved_upc end   as unresolved_upc
        , case when l.is_customer_held then l.existing_customer_key else l.customer_key end      as customer_key
    -- ship_to_customer_key removed (retired, spec v1.2 O8; EDW-56)
        , case when l.is_header_held then l.existing_sales_channel_key else l.sales_channel_key end as sales_channel_key
        , case when l.is_header_held then l.existing_source_sales_origin_id else nullif(l.SALESORIGINID, '') end as source_sales_origin_id  -- v1.1 (EDW-16, Decision 4): raw D365 origin carried on the fact as a non-key lineage attribute, so an unmapped/blank row can be traced without a join back to silver.
        , l.warehouse_key
        , cast(-1 as bigint) as employee_sales_hierarchy_key  -- 2026-09-16 fix (Chris review, same as EDW-23/fact_sales_invoice): coalesced to the reserved -1 UNKNOWN member rather than left null -- no worker/sales-rep table found in the warehouse scan, shared gap with fact_sales_invoice
        , cast(null as bigint) as campaign_key  -- Phase 2 per spec
    -- promotion_key removed (deprecated, spec v1.2 O1; EDW-56): promotion analysis routes through FACT_DISCOUNT_APPLICATION.
        , case when l.is_customer_held then coalesce(l.existing_customer_segment_key, l.current_customer_segment_key)
               else l.current_customer_segment_key
          end                                                         as customer_segment_key  -- EDW-56 (spec 4.11): the customer's segment when the line is written, held after that. NULL on the -1 customer.

    -- Dates
        , case when l.is_header_held then l.existing_order_date else cast(l.order_created_datetime_ct as date) end as order_date  -- EDW-56: Central calendar day
        , case when l.SHIPPINGDATEREQUESTED is not null and l.SHIPPINGDATEREQUESTED > timestamp('1901-01-01') and l.SHIPPINGDATEREQUESTED < timestamp('2040-01-01')
               then cast(l.SHIPPINGDATEREQUESTED as date)
               else null end                                          as requested_ship_date  -- EDW-21 v1.1 (2026-10-07): placeholder rule, see requested_ship_date_key
        , cast(null as date) as requested_delivery_date  -- Phase 2 per spec

    -- Status
    -- D365 SalesStatus enum: 0=None, 1=Backorder, 2=Delivered, 3=Invoiced, 4=Canceled.
    -- Status at first observation (spec 7.5); held after insert since EDW-56. A full refresh restates it to current.
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
        , case when l.is_customer_held then coalesce(l.existing_is_dso_order_flag, l.dso_flag_at_order)
               else l.dso_flag_at_order
          end                                                         as is_dso_order_flag  -- EDW-56 (spec 4.9): DIM_CUSTOMER is_dso_member_flag on the version in effect at the order date. Membership history starts Oct 14 2026; earlier orders read that first version. NULL on the -1 customer.

    -- Quantities
        , l.QTYORDERED                                                as ordered_qty
        , coalesce(nullif(l.SALESUNIT, ''), 'ea')                    as qty_uom

    -- Amounts
        , l.SALESPRICE                                                as unit_price
        , l.QTYORDERED * l.SALESPRICE                                 as line_amount
        , {{ amount('l.QTYORDERED * l.LINEDISC') }}                    as line_discount_amount  -- 2026-09-16 fix (Chris review): LINEDISC is a per-unit amount, not a line total -- LINEDISC-as-is missed SalesLine.LINEAMOUNT on 125K of 2.6M lines (~$3.5M absolute); QTYORDERED * (SALESPRICE - LINEDISC) missed on 358 more. QTYORDERED * LINEDISC is the reconciling formula.
        , {{ amount('l.LINEAMOUNT') }}                                as net_line_amount  -- 2026-09-16 fix: sourced from SalesLine.LINEAMOUNT directly (source truth) instead of re-derived as QTYORDERED * SALESPRICE - LINEDISC
        , l.CURRENCYCODE                                              as transaction_currency_code
        , cast(null as decimal(19,8)) as fx_rate_to_usd  -- Phase 2 per spec
        , cast(null as decimal(19,4)) as net_line_amount_usd  -- Phase 2 per spec

    -- Payment (EDW-56, spec 4.8 / 7.9)
        , case when l.is_header_held then l.existing_payment_terms_code
               when nullif(trim(l.PAYMENT), '') is null then null
               when upper(trim(l.PAYMENT)) in ('PREPAID', 'NET10', 'NET30', 'NET45', 'NET60') then upper(trim(l.PAYMENT))
               else 'UNKNOWN'
          end                                                         as payment_terms_code  -- SalesTable.PAYMENT upper-cased; blank to NULL; anything else UNKNOWN. Same rule as fact_orders_returns / fact_sales_invoice.
        , case when l.is_header_held then l.existing_payment_mode_code
               else nullif(trim(l.PAYMMODE), '')
          end                                                         as payment_mode_code  -- SalesTable.PAYMMODE as sourced (CC-BT, Credit, RevPoints, Check, ACH); blank to NULL.

    -- B2B Context
        , case when l.is_header_held then l.existing_customer_purchase_order else nullif(l.PURCHORDERFORMNUM, '') end as customer_purchase_order

    -- Fulfillment Context
        , case when l.is_header_held then l.existing_shipping_method else nullif(l.DLVMODE, '') end as shipping_method  -- raw D365 delivery-mode code; no code-to-name lookup table found
        , nullif(l.INVENTLOCATIONID, '')                              as warehouse_id_at_order

    -- Audit
        , 'silver_d365_sales_line + silver_d365_sales_table'          as record_source_table
        , current_timestamp()                                        as etl_insert_datetime  -- set at insert only; not in merge_update_columns
        , l.MODIFIEDDATE                                              as etl_source_modified_datetime  -- not a spec field; needed as the incremental-merge watermark (spec 6/Audit says etl_insert_datetime is the only timestamp needed since rows are immutable, but the ETL mechanics still need a change-detection column upstream)
        , sha2(concat_ws('||', l.SALESID, cast(l.LINENUM as string), 'D365', cast(l.QTYORDERED as string), cast(l.SALESPRICE as string)), 256) as row_hash

    -- EDW-177: true when D365 has deleted the line. Current-demand reads filter it. Appended after row_hash
    -- so a full refresh and the in-place column add give the same position. Not in row_hash.
        , l.is_source_deleted                                         as is_source_deleted_flag

    from held l

)

select * from final