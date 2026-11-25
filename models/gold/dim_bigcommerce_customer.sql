with

customer as (

    select c.*
    from {{ ref('silver_bigcommerce_customer') }} c

),

customer_group as (

    select
          g.store_code
        , g.id
        , g.name
    from {{ ref('silver_bigcommerce_customer_group') }} g

),

order_stats as (

    select
          o.bigcommerce_customer_key
        , min(o.order_date)                     as first_order_date
        , max(o.order_date)                     as last_order_date
        , count(*)                              as sale_order_count
        , sum(o.units_ordered)                  as units_ordered
        , sum(o.net_merchandise_amount)         as lifetime_net_merchandise_amount
        , sum(o.net_merchandise_amount_usd)     as lifetime_net_merchandise_amount_usd
        , sum(case when o.order_date >= date_sub(current_date(), 365) then o.net_merchandise_amount_usd else 0 end) as net_merchandise_amount_usd_365d
        , sum(case when o.order_date >= date_sub(current_date(), 365) then 1 else 0 end) as sale_order_count_365d
    from {{ ref('fact_bigcommerce_order') }} o
    where o.is_sale_order
      and o.bigcommerce_customer_key <> {{ unknown_member_key() }}
    group by o.bigcommerce_customer_key

),

final as (

    select
          xxhash64(c.store_code, c.id)                                  as bigcommerce_customer_key
        , c.store_code
        , c.id                                                          as bigcommerce_customer_id
        , c.email                                                       as customer_email
        , c.first_name
        , c.last_name
        , c.company
        , c.phone
        , c.customer_group_id
        , g.name                                                        as customer_group_name
        , c.accepts_product_review_abandoned_cart_emails                as accepts_abandoned_cart_emails
        , c.tax_exempt_category
        , c.origin_channel_id
        , c.date_created                                                as customer_created_datetime_utc
        , c.date_modified                                               as customer_modified_datetime_utc
        , s.first_order_date
        , s.last_order_date
        , datediff(current_date(), s.last_order_date)                   as days_since_last_order
        , coalesce(s.sale_order_count, 0)                               as sale_order_count
        , coalesce(s.sale_order_count_365d, 0)                          as sale_order_count_365d
        , coalesce(s.sale_order_count, 0) > 1                           as is_repeat_customer
        , coalesce(s.units_ordered, 0)                                  as units_ordered
        , {{ amount('coalesce(s.lifetime_net_merchandise_amount, 0)') }}     as lifetime_net_merchandise_amount
        , {{ amount('coalesce(s.lifetime_net_merchandise_amount_usd, 0)') }} as lifetime_net_merchandise_amount_usd
        , {{ amount('coalesce(s.net_merchandise_amount_usd_365d, 0)') }}     as net_merchandise_amount_usd_365d
        , {{ audit_columns() }}
    from customer c
    left join customer_group g
        on g.store_code = c.store_code
        and g.id = c.customer_group_id
    left join order_stats s
        on s.bigcommerce_customer_key = xxhash64(c.store_code, c.id)

    union all

    select
          {{ unknown_member_key() }}                                    as bigcommerce_customer_key
        , cast(null as string)                                          as store_code
        , cast(null as bigint)                                          as bigcommerce_customer_id
        , cast(null as string)                                          as customer_email
        , 'Unknown'                                                     as first_name
        , cast(null as string)                                          as last_name
        , cast(null as string)                                          as company
        , cast(null as string)                                          as phone
        , cast(null as bigint)                                          as customer_group_id
        , 'Guest / Unknown'                                             as customer_group_name
        , cast(null as boolean)                                         as accepts_abandoned_cart_emails
        , cast(null as string)                                          as tax_exempt_category
        , cast(null as bigint)                                          as origin_channel_id
        , cast(null as timestamp)                                       as customer_created_datetime_utc
        , cast(null as timestamp)                                       as customer_modified_datetime_utc
        , cast(null as date)                                            as first_order_date
        , cast(null as date)                                            as last_order_date
        , cast(null as int)                                             as days_since_last_order
        , cast(0 as bigint)                                             as sale_order_count
        , cast(0 as bigint)                                             as sale_order_count_365d
        , false                                                         as is_repeat_customer
        , cast(0 as bigint)                                             as units_ordered
        , {{ amount('0') }}                                             as lifetime_net_merchandise_amount
        , {{ amount('0') }}                                             as lifetime_net_merchandise_amount_usd
        , {{ amount('0') }}                                             as net_merchandise_amount_usd_365d
        , {{ audit_columns() }}

)

select * from final
