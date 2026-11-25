with

orders as (

    select o.*
    from {{ ref('silver_bigcommerce_orders') }} o

),

customer as (

    select
          c.store_code
        , c.id
    from {{ ref('silver_bigcommerce_customer') }} c

),

coupon as (

    select
          oc.store_code
        , oc.order_id
        , array_join(array_sort(collect_set(oc.code)), ', ') as coupon_codes
    from {{ ref('silver_bigcommerce_order_coupon') }} oc
    group by oc.store_code, oc.order_id

),

line as (

    select
          op.store_code
        , op.order_id
        , count(*) as line_count
    from {{ ref('silver_bigcommerce_order_product') }} op
    group by op.store_code, op.order_id

),

sales_channel as (

    select
          sc.sales_channel_key
        , sc.storefront_code
    from {{ ref('dim_sales_channel') }} sc
    where sc.storefront_code is not null

),

dim_date as (

    select d.date_key
    from {{ ref('dim_date') }} d

),

-- Spot rate to USD at the order date, ranges built the same way as fact_orders_returns (EDW-169).
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

joined as (

    select
          o.*
        , case when o.customer_id <> 0 and c.id is not null then xxhash64(o.store_code, o.customer_id) end as resolved_customer_key
        , case when o.currency_code = 'USD' then cast(1 as decimal(19,8)) else fx.fx_rate_to_usd end        as fx_rate_to_usd
        , cp.coupon_codes
        , l.line_count
        , sc.sales_channel_key
        , dd.date_key
        , o.subtotal_ex_tax - o.discount_amount - o.coupon_discount                                         as net_merchandise_amount
    from orders o
    left join customer c
        on c.store_code = o.store_code
        and c.id = o.customer_id
    left join fx_rate fx
        on fx.from_currency_code = o.currency_code
        and o.order_date between fx.rate_start_date and fx.rate_end_date
    left join coupon cp
        on cp.store_code = o.store_code
        and cp.order_id = o.id
    left join line l
        on l.store_code = o.store_code
        and l.order_id = o.id
    left join sales_channel sc
        on sc.storefront_code = o.store_code
    left join dim_date dd
        on dd.date_key = cast(date_format(o.order_date, 'yyyyMMdd') as int)

),

sequenced as (

    select
          j.*
        , case when j.is_sale_order then
              row_number() over (
                  partition by j.store_code, coalesce(cast(j.resolved_customer_key as string), j.email), j.is_sale_order
                  order by j.date_created, j.id
              )
          end as customer_order_sequence
        , case when j.is_sale_order then
              lag(j.order_date) over (
                  partition by j.store_code, coalesce(cast(j.resolved_customer_key as string), j.email), j.is_sale_order
                  order by j.date_created, j.id
              )
          end as prior_order_date
    from joined j

),

final as (

    select
          xxhash64(s.store_code, s.id)                                          as bigcommerce_order_key
        , s.store_code
        , s.id                                                                  as bigcommerce_order_id
        , coalesce(s.resolved_customer_key, {{ unknown_member_key() }})         as bigcommerce_customer_key
        , s.customer_id                                                         as bigcommerce_customer_id
        , coalesce(s.sales_channel_key, {{ unknown_member_key() }})             as sales_channel_key
        , coalesce(s.date_key, {{ unknown_member_key() }})                      as order_date_key
        , s.order_date
        , s.date_created                                                        as order_created_datetime_utc
        , s.date_modified                                                       as order_modified_datetime_utc
        , s.date_shipped                                                        as order_shipped_datetime_utc
        , s.status                                                              as order_status
        , s.status_id                                                           as order_status_id
        , s.payment_status
        , s.payment_method
        , s.order_source
        , s.external_source
        , s.is_sale_order
        , coalesce(s.is_deleted, false)                                         as is_archived
        , s.customer_id = 0                                                     as is_guest_order
        , s.email                                                               as customer_email
        , s.is_email_opt_in
        , s.customer_order_sequence
        , s.customer_order_sequence = 1                                         as is_first_order
        , datediff(s.order_date, s.prior_order_date)                            as days_since_prior_order
        , s.cart_id
        , s.coupon_codes
        , s.city                                                                as billing_city
        , s.state                                                               as billing_state
        , s.zip                                                                 as billing_zip
        , s.country_iso_2                                                       as billing_country_iso_2
        , s.geoip_country_iso_2
        , s.customer_locale
        , coalesce(s.line_count, 0)                                             as line_count
        , s.items_total                                                         as units_ordered
        , s.items_shipped                                                       as units_shipped
        , s.currency_code
        , s.fx_rate_to_usd
        , {{ amount('s.subtotal_ex_tax') }}                                     as subtotal_amount
        , {{ amount('s.discount_amount') }}                                     as automatic_discount_amount
        , {{ amount('s.coupon_discount') }}                                     as coupon_discount_amount
        , {{ amount('s.net_merchandise_amount') }}                              as net_merchandise_amount
        , {{ amount('s.shipping_cost_ex_tax') }}                                as shipping_amount
        , {{ amount('s.handling_cost_ex_tax') }}                                as handling_amount
        , {{ amount('s.total_tax_amount') }}                                    as tax_amount
        , {{ amount('s.total_inc_tax') }}                                       as order_total_amount
        , {{ amount('s.refunded_amount') }}                                     as refunded_amount
        , {{ amount('s.gift_certificate_amount') }}                             as gift_certificate_amount
        , {{ amount('s.store_credit_amount') }}                                 as store_credit_amount
        , {{ amount('s.subtotal_ex_tax * s.fx_rate_to_usd') }}                  as subtotal_amount_usd
        , {{ amount('(s.discount_amount + s.coupon_discount) * s.fx_rate_to_usd') }} as discount_amount_usd
        , {{ amount('s.net_merchandise_amount * s.fx_rate_to_usd') }}           as net_merchandise_amount_usd
        , {{ amount('s.shipping_cost_ex_tax * s.fx_rate_to_usd') }}             as shipping_amount_usd
        , {{ amount('s.total_inc_tax * s.fx_rate_to_usd') }}                    as order_total_amount_usd
        , {{ amount('s.refunded_amount * s.fx_rate_to_usd') }}                  as refunded_amount_usd
        , 'phoenix_raw.big_commerce_' || lower(s.store_code) || '.orders'       as record_source_table
        , {{ audit_columns() }}
    from sequenced s

)

select * from final
