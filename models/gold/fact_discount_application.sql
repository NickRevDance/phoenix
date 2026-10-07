{{ config(
    materialized = 'incremental',
    unique_key = 'discount_line_key',
    incremental_strategy = 'merge',
    on_schema_change = 'sync_all_columns',
    merge_exclude_columns = ['etl_insert_datetime']
) }}

with parent as (

    select

          i.sales_invoice_key
        , i.d365_invoice_rec_id
        , i.invoice_id
        , i.invoice_line_number
        , i.order_id
        , i.order_line_number
        , i.invoice_date
        , i.invoice_date_key
        , i.order_date_key
        , i.product_key
        , i.customer_key
        , i.sales_channel_key
        , i.invoiced_qty
        , i.unit_price
        , i.gross_sales_amount
        , i.line_discount_amount
        , i.header_discount_allocated
        , i.total_discount_amount
        , i.transaction_currency_code
        , i.etl_source_modified_datetime

    from {{ ref('fact_sales_invoice') }} i

    where i.total_discount_amount <> 0

    {% if is_incremental() %}
      and (
            i.etl_source_modified_datetime > (select coalesce(max(t.etl_source_modified_datetime), timestamp('1900-01-01')) from {{ this }} t) - interval 2 days
            or i.sales_invoice_key in (select t.sales_invoice_key from {{ this }} t where t.product_key = '-1')  -- same self-heal as the parent so an Unknown product resolves here too
          )
    {% endif %}

),

line_context as (

    -- customer and item discount groups drive D365 trade agreement lookup
    select

          p.sales_invoice_key
        , cu.LINEDISC          as customer_disc_group
        , ig.item_disc_group

    from parent p

    left join {{ ref('silver_d365_cust_invoice_trans') }} tr
        on p.d365_invoice_rec_id = tr.RECID

    left join {{ ref('silver_d365_cust_invoice_jour') }} j
        on tr.PARENTRECID = j.REC

    left join {{ ref('silver_d365_customer_table') }} cu
        on j.INVOICEACCOUNT = cu.ACCOUNTNUM

    left join {{ ref('silver_d365_item_sales_disc_group') }} ig
        on tr.ITEMID = ig.ITEMID

),

agreement as (

    -- customer-group agreements only, same filter as DIM_PROMOTION
    select

          a.RECID
        , a.ACCOUNTRELATION
        , a.ITEMRELATION
        , a.PERCENT1
        , case when a.FROMDATE = date('1900-01-01') then cast(null as date) else cast(a.FROMDATE as date) end as from_date
        , case when a.TODATE = date('1900-01-01') then cast(null as date) else cast(a.TODATE as date) end as to_date

    from {{ ref('silver_d365_price_disc_table_sales') }} a

    where a.MODULE = 1
      and a.ACCOUNTCODE = 1

),

matched as (

    -- an invoice line resolves to an agreement when customer group + item group match, the agreement is
    -- in force at invoice date, and the agreement percent ties to the realized discount percent (+/- 0.5 pt).
    -- Ties between duplicate agreement rows go to the lowest RECID.
    select

          p.sales_invoice_key
        , a.RECID as agreement_recid
        , a.ACCOUNTRELATION as agreement_disc_group
        , a.PERCENT1 as agreement_percent
        , row_number() over (partition by p.sales_invoice_key order by a.RECID) as rn

    from parent p

    inner join line_context lc
        on p.sales_invoice_key = lc.sales_invoice_key

    inner join agreement a
        on lc.customer_disc_group = a.ACCOUNTRELATION
        and lc.item_disc_group = a.ITEMRELATION
        and (a.from_date is null or a.from_date <= p.invoice_date)
        and (a.to_date is null or a.to_date >= p.invoice_date)

    where p.gross_sales_amount <> 0
      and abs(abs(p.line_discount_amount / p.gross_sales_amount) * 100 - a.PERCENT1) < 0.5

),

promotion as (

    select

          d.promotion_key
        , d.source_promotion_id

    from {{ ref('dim_promotion') }} d

    where d.version_number = 1  -- fact key resolution house rule: latest version, not is_current_row
      and d.source_system = 'D365'

),

components as (

    -- sequence 1: the line-level discount carried on CustInvoiceTrans (D365 exposes one net per-unit LINEDISC)
    select

          p.sales_invoice_key
        , 1 as discount_sequence
        , 'LINEDISC' as discount_source_field
        , case when m.agreement_recid is not null then 'TRADE_AGREEMENT' else 'LINE_DISCOUNT' end as discount_type
        , p.line_discount_amount as discount_amount
        , p.gross_sales_amount as base_amount_before_discount
        , m.agreement_recid
        , m.agreement_disc_group
        , coalesce(pr.promotion_key, -1) as promotion_key

    from parent p

    left join matched m
        on p.sales_invoice_key = m.sales_invoice_key
        and m.rn = 1

    left join promotion pr
        on cast(m.agreement_recid as string) = pr.source_promotion_id

    where p.line_discount_amount <> 0

    union all

    -- sequence 2: allocated header discount (ENDDISC is 0 on every D365 invoice today, so this branch is dormant)
    select

          p.sales_invoice_key
        , 2 as discount_sequence
        , 'ENDDISC' as discount_source_field
        , 'HEADER_DISCOUNT' as discount_type
        , p.header_discount_allocated as discount_amount
        , p.gross_sales_amount - p.line_discount_amount as base_amount_before_discount
        , cast(null as bigint) as agreement_recid
        , cast(null as string) as agreement_disc_group
        , cast(0 as bigint) as promotion_key

    from parent p

    where coalesce(p.header_discount_allocated, 0) <> 0

),

final as (

    select

    -- Core ID
          {{ generate_surrogate_key(['p.d365_invoice_rec_id', 'c.discount_source_field', "'D365'"]) }} as discount_line_key
        , p.invoice_id
        , p.invoice_line_number
        , c.discount_sequence
        , c.discount_source_field
        , 'D365' as source_system
        , p.d365_invoice_rec_id

    -- Lineage
        , p.order_id
        , p.order_line_number

    -- Parent FKs
        , c.sales_invoice_key
        , cast(null as bigint) as orders_returns_key  -- Source once available: needs the INVENTTRANSID order-line linkage (invoice spec Open Decision 12, Phase 2)
        , cast(null as bigint) as order_line_key  -- Source once available: same INVENTTRANSID linkage

    -- Dim FKs
        , p.invoice_date_key
        , p.order_date_key as application_date_key
        , p.product_key
        , p.customer_key
        , p.sales_channel_key
        , c.promotion_key
        , cast(null as bigint) as customer_segment_key  -- Phase 2 per spec

    -- Classification
        , c.discount_type
        , cast(null as string) as discount_subtype
        , cast(null as string) as discount_reason  -- spec 1.2: only populated on promotion_key = 0 rows; none in D365 source
        , count(*) over (partition by c.sales_invoice_key) > 1 as is_stacked_flag
        , c.discount_sequence as stack_position

    -- Amounts
        , {{ amount('c.discount_amount') }} as discount_amount
        , cast(case when c.base_amount_before_discount <> 0 then round(c.discount_amount / c.base_amount_before_discount, 4) end as decimal(9,4)) as discount_pct
        , {{ amount('case when p.invoiced_qty <> 0 then c.discount_amount / p.invoiced_qty end') }} as discount_per_unit
        , {{ amount('p.invoiced_qty') }} as quantity
        , {{ amount('c.base_amount_before_discount') }} as base_amount_before_discount

    -- Funding
        , cast(null as string) as funding_source  -- Source once available: F3 identification method for vendor-funded D365 rows is still open
        , cast(null as decimal(19,4)) as vendor_funded_amount  -- Phase 2 per spec
        , cast(null as decimal(19,4)) as revolution_funded_amount  -- Phase 2 per spec

    -- Promo Reference
        , cast(null as string) as coupon_code
        , p.transaction_currency_code as discount_currency_code
        , cast(null as decimal(19,8)) as fx_rate_to_usd  -- Phase 2 per spec
        , cast(null as decimal(19,4)) as discount_amount_usd  -- Phase 2 per spec

    -- Source Ref
        , cast(c.agreement_recid as string) as d365_discount_id  -- PriceDiscTable RECID of the matched agreement; NULL when unresolved
        , c.agreement_disc_group as d365_price_group
        , cast(null as string) as bc_promotion_id  -- Source once available: EDW-33 BigCommerce promotions ingestion
        , cast(null as string) as bc_coupon_id  -- Source once available: EDW-33

    -- Audit
        , 'fact_sales_invoice + silver_d365_price_disc_table_sales' as record_source_table
        , current_timestamp() as etl_insert_datetime
        , current_timestamp() as etl_update_datetime
        , p.etl_source_modified_datetime
        , sha2(concat_ws('||', cast(p.d365_invoice_rec_id as string), c.discount_source_field, c.discount_type, cast(c.discount_amount as string), cast(c.promotion_key as string)), 256) as row_hash

    from components c

    inner join parent p
        on c.sales_invoice_key = p.sales_invoice_key

)

select * from final
