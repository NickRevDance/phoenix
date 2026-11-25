with

variant as (

    select v.*
    from {{ ref('silver_bigcommerce_product_variant') }} v

),

product as (

    select p.*
    from {{ ref('silver_bigcommerce_product') }} p

),

brand as (

    select
          b.store_code
        , b.id
        , b.name
    from {{ ref('silver_bigcommerce_brand') }} b

),

category as (

    select
          pc.store_code
        , pc.product_id
        , array_join(array_sort(collect_set(ct.name)), ', ')    as category_names
    from {{ ref('silver_bigcommerce_product_category') }} pc
    inner join {{ ref('silver_bigcommerce_category_tree') }} ct
        on ct.store_code = pc.store_code
        and ct.category_id = pc.category_id
    group by pc.store_code, pc.product_id

),

d365_product as (

    select distinct dp.UPC
    from {{ ref('dim_product') }} dp
    where dp.version_number = 1
      and dp.product_key <> '-1'

),

final as (

    select
          xxhash64(v.store_code, v.id)                                  as bigcommerce_variant_key
        , v.store_code
        , v.id                                                          as bigcommerce_variant_id
        , v.product_id                                                  as bigcommerce_product_id
        , v.sku
        , case when dp.UPC is not null then md5(dp.UPC) else '-1' end   as product_key
        , p.name                                                        as product_name
        , p.sku                                                         as product_sku
        , coalesce(b.name, p.brand_name)                                as brand_name
        , c.category_names
        , p.type                                                        as product_type
        , p.is_visible
        , p.is_featured
        , p.availability
        , v.purchasing_disabled
        , p.custom_url                                                  as product_url_path
        , {{ amount('coalesce(v.price, p.price)') }}                    as list_price
        , {{ amount('nullif(coalesce(v.sale_price, p.sale_price), 0)') }} as sale_price
        , {{ amount('coalesce(v.calculated_price, p.calculated_price)') }} as calculated_price
        , {{ amount('nullif(coalesce(v.retail_price, p.retail_price), 0)') }} as retail_price
        , {{ amount('nullif(coalesce(v.cost_price, p.cost_price), 0)') }} as cost_price
        , v.inventory_level
        , v.inventory_warning_level
        , p.inventory_tracking
        , p.total_sold                                                  as product_total_sold
        , p.view_count                                                  as product_view_count
        , p.reviews_count                                               as product_reviews_count
        , cast(p.reviews_rating_sum / nullif(p.reviews_count, 0) as decimal(9,4)) as product_average_rating
        , p.date_created                                                as product_created_datetime_utc
        , p.date_modified                                               as product_modified_datetime_utc
        , {{ audit_columns() }}
    from variant v
    left join product p
        on p.store_code = v.store_code
        and p.id = v.product_id
    left join brand b
        on b.store_code = p.store_code
        and b.id = p.brand_id
    left join category c
        on c.store_code = v.store_code
        and c.product_id = v.product_id
    left join d365_product dp
        on dp.UPC = trim(v.sku)

    union all

    select
          {{ unknown_member_key() }}, cast(null as string), cast(null as bigint), cast(null as bigint), cast(null as string), '-1'
        , 'Unknown', cast(null as string), cast(null as string), cast(null as string), cast(null as string)
        , cast(null as boolean), cast(null as boolean), cast(null as string), cast(null as boolean), cast(null as string)
        , {{ amount('null') }}, {{ amount('null') }}, {{ amount('null') }}, {{ amount('null') }}, {{ amount('null') }}
        , cast(null as bigint), cast(null as bigint), cast(null as string)
        , cast(null as bigint), cast(null as bigint), cast(null as bigint), cast(null as decimal(9,4))
        , cast(null as timestamp), cast(null as timestamp)
        , {{ audit_columns() }}

)

select * from final
