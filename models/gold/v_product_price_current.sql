{{ config(materialized = 'view') }}

select

      product_key
    , product_id
    , sku

    , max(case when price_type = 'LIST' then list_price end) as current_list_price
    , max(case when price_type = 'LIST' then effective_date end) as list_price_effective_date

    , max(case when price_type = 'SALE' then sale_price end) as current_sale_price
    , max(case when price_type = 'SALE' then effective_date end) as sale_price_effective_date

    , max(case when price_type = 'MSRP' then msrp end) as current_msrp
    , max(case when price_type = 'MSRP' then effective_date end) as msrp_effective_date

    , max(case when price_type = 'B2B' then b2b_price end) as current_b2b_price
    , max(case when price_type = 'B2B' then effective_date end) as b2b_price_effective_date

    , max(case when price_type = 'LIST' then is_on_sale_flag end) as is_on_sale_flag
    , max(case when price_type = 'SALE' then discount_pct end) as discount_pct

    , max(price_currency_code) as price_currency_code

from {{ ref('fact_product_price') }}
where is_current
group by product_key, product_id, sku
