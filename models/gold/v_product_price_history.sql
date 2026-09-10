{{ config(materialized = 'view') }}

select

      product_key
    , product_id
    , sku
    , source_system
    , price_type
    , effective_date
    , expiration_date
    , list_price
    , sale_price
    , msrp
    , b2b_price
    , price_currency_code
    , is_current
    , prior_price
    , price_change_amount
    , price_change_pct

    , lead(case price_type
            when 'LIST' then list_price
            when 'SALE' then sale_price
            when 'MSRP' then msrp
            when 'B2B' then b2b_price
          end) over (
            partition by product_id, price_type, source_system
            order by effective_date
          ) as next_price

from {{ ref('fact_product_price') }}
order by product_id, price_type, effective_date
