with

line as (

    select op.*
    from {{ ref('silver_bigcommerce_order_product') }} op

),

orders as (

    select
          o.bigcommerce_order_key
        , o.store_code
        , o.bigcommerce_order_id
        , o.bigcommerce_customer_key
        , o.sales_channel_key
        , o.order_date_key
        , o.order_date
        , o.order_status
        , o.is_sale_order
        , o.is_first_order
        , o.currency_code
        , o.fx_rate_to_usd
    from {{ ref('fact_bigcommerce_order') }} o

),

options as (

    select
          oo.store_code
        , oo.order_product_id
        , coalesce(max(case when oo.display_name = 'Size' then oo.display_value end), max(case when oo.display_name = 'Expandable Size Grid' then oo.display_value end))   as size
        , coalesce(max(case when oo.display_name = 'Color' then oo.display_value end), max(case when oo.display_name = 'Expandable Color Grid' then oo.display_value end)) as color
        , max(case when oo.display_name = 'Estimated Ship Date' then oo.display_value end) as estimated_ship_date_text
        , max(case when oo.display_name = 'Customization' then oo.display_value end) as customization_text
        , max(case when oo.display_name = 'Roster' then oo.display_value end)        as roster_text
        , max(oo.display_name in ('Customization', 'Roster'))                         as is_customized
    from {{ ref('silver_bigcommerce_order_product_option') }} oo
    group by oo.store_code, oo.order_product_id

),

discount as (

    select
          d.store_code
        , d.order_product_id
        , sum(d.amount)                                                                as line_discount_amount
        , sum(case when d.code is not null then d.amount else 0 end)                   as line_coupon_discount_amount
        , sum(case when d.target = 'order' then d.amount else 0 end)                   as line_order_discount_amount
        , array_join(array_sort(collect_set(coalesce(d.code, d.name))), ', ')          as discount_names
    from {{ ref('silver_bigcommerce_order_product_discount') }} d
    group by d.store_code, d.order_product_id

),

refund as (

    select
          ri.store_code
        , ri.item_id                                                                   as order_product_id
        , sum(ri.quantity)                                                             as quantity_refunded
    from {{ ref('silver_bigcommerce_order_refund_item') }} ri
    where upper(ri.item_type) = 'PRODUCT'
    group by ri.store_code, ri.item_id

),

variant as (

    select
          v.store_code
        , v.id
    from {{ ref('silver_bigcommerce_product_variant') }} v

),

product as (

    select distinct p.UPC
    from {{ ref('dim_product') }} p
    where p.version_number = 1
      and p.product_key <> '-1'

),

final as (

    select
          xxhash64(l.store_code, l.id)                                                  as bigcommerce_order_line_key
        , o.bigcommerce_order_key
        , l.store_code
        , l.order_id                                                                    as bigcommerce_order_id
        , l.id                                                                          as bigcommerce_order_line_id
        , o.bigcommerce_customer_key
        , o.sales_channel_key
        , o.order_date_key
        , o.order_date
        , o.order_status
        , o.is_sale_order
        , o.is_first_order
        , case when v.id is not null then xxhash64(l.store_code, l.variant_id)
               else {{ unknown_member_key() }} end                                      as bigcommerce_variant_key
        , case when p.UPC is not null then md5(p.UPC) else '-1' end                     as product_key
        , l.product_id                                                                  as bigcommerce_product_id
        , l.variant_id                                                                  as bigcommerce_variant_id
        , l.sku
        , l.name                                                                        as product_name
        , op.size
        , op.color
        , coalesce(op.is_customized, false)                                             as is_customized
        , op.customization_text
        , op.roster_text
        , op.estimated_ship_date_text
        , d.discount_names
        , l.quantity
        , l.quantity_shipped
        , coalesce(r.quantity_refunded, 0)                                              as quantity_refunded
        , coalesce(l.is_refunded, false)                                                as is_refunded
        , o.currency_code
        , o.fx_rate_to_usd
        , {{ amount('l.price_ex_tax') }}                                                as unit_price
        , {{ amount('l.total_ex_tax') }}                                                as gross_line_amount
        , {{ amount('coalesce(d.line_discount_amount, 0)') }}                           as line_discount_amount
        , {{ amount('coalesce(d.line_coupon_discount_amount, 0)') }}                    as line_coupon_discount_amount
        , {{ amount('coalesce(d.line_order_discount_amount, 0)') }}                     as line_order_discount_amount
        , {{ amount('l.total_ex_tax - coalesce(d.line_discount_amount, 0)') }}          as net_line_amount
        , {{ amount('l.total_tax') }}                                                   as line_tax_amount
        , {{ amount('coalesce(l.refunded_amount, 0)') }}                                as refunded_line_amount
        , {{ amount('l.total_ex_tax * o.fx_rate_to_usd') }}                             as gross_line_amount_usd
        , {{ amount('coalesce(d.line_discount_amount, 0) * o.fx_rate_to_usd') }}        as line_discount_amount_usd
        , {{ amount('(l.total_ex_tax - coalesce(d.line_discount_amount, 0)) * o.fx_rate_to_usd') }} as net_line_amount_usd
        , 'phoenix_raw.big_commerce_' || lower(l.store_code) || '.order_product'        as record_source_table
        , {{ audit_columns() }}
    from line l
    inner join orders o
        on o.store_code = l.store_code
        and o.bigcommerce_order_id = l.order_id
    left join options op
        on op.store_code = l.store_code
        and op.order_product_id = l.id
    left join discount d
        on d.store_code = l.store_code
        and d.order_product_id = l.id
    left join refund r
        on r.store_code = l.store_code
        and r.order_product_id = l.id
    left join variant v
        on v.store_code = l.store_code
        and v.id = l.variant_id
    left join product p
        on p.UPC = trim(l.sku)

)

select * from final
