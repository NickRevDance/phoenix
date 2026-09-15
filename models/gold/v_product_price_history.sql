{{ config(materialized = 'view') }}

-- v1.1 change: partitions on product_key (variant) + price_currency_code
-- instead of product_id -- currency is now a grain component (Business
-- Rule/Section 3, Open Decision #4 closed for currency), so history has
-- to stay split by currency or CAD/USD windows would interleave into a
-- meaningless sequence for the same variant.

select

      product_key
    , product_id
    , sku
    , source_system
    , price_type
    , price_currency_code
    , effective_date
    , expiration_date
    , list_price
    , is_current
    , price_status
    , prior_price
    , price_change_amount
    , price_change_pct

    , lead(list_price) over (
        partition by product_key, price_type, price_currency_code
        order by effective_date
      ) as next_price

from {{ ref('fact_product_price') }}
order by product_key, price_currency_code, effective_date
