with

discount as (

    select d.*
    from {{ ref('silver_bigcommerce_order_product_discount') }} d

),

line as (

    select
          l.bigcommerce_order_line_key
        , l.store_code
        , l.bigcommerce_order_line_id
        , l.bigcommerce_order_key
        , l.bigcommerce_order_id
        , l.bigcommerce_customer_key
        , l.bigcommerce_variant_key
        , l.product_key
        , l.sales_channel_key
        , l.order_date_key
        , l.order_date
        , l.is_sale_order
        , l.currency_code
        , l.fx_rate_to_usd
    from {{ ref('fact_bigcommerce_order_line') }} l

),

final as (

    select
          xxhash64(d.store_code, d.order_product_id, d.id)                  as bigcommerce_order_line_discount_key
        , l.bigcommerce_order_line_key
        , l.bigcommerce_order_key
        , d.store_code
        , l.bigcommerce_order_id
        , d.order_product_id                                                as bigcommerce_order_line_id
        , l.bigcommerce_customer_key
        , l.bigcommerce_variant_key
        , l.product_key
        , l.sales_channel_key
        , l.order_date_key
        , l.order_date
        , l.is_sale_order
        , d.id                                                              as bigcommerce_discount_id
        , d.name                                                            as discount_name
        , d.code                                                            as coupon_code
        , d.target                                                          as discount_target
        , d.code is not null                                                as is_coupon_discount
        , l.currency_code
        , l.fx_rate_to_usd
        , {{ amount('d.amount') }}                                          as discount_amount
        , {{ amount('d.amount * l.fx_rate_to_usd') }}                       as discount_amount_usd
        , 'phoenix_raw.big_commerce_' || lower(d.store_code) || '.order_product_discount' as record_source_table
        , {{ audit_columns() }}
    from discount d
    inner join line l
        on l.store_code = d.store_code
        and l.bigcommerce_order_line_id = d.order_product_id

)

select * from final
