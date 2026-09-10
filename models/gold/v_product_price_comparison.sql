{{ config(materialized = 'view') }}

select

      c.product_key
    , c.product_id
    , c.sku
    , d.product_group
    , d.summary_class
    , d.product_supplier

    , c.current_list_price as list_price
    , c.current_sale_price as sale_price
    , c.current_msrp as msrp
    , c.current_b2b_price as b2b_price
    , c.price_currency_code

    , c.current_msrp - c.current_list_price as list_vs_msrp_variance
    , case when c.current_list_price is not null and c.current_list_price <> 0
        then (c.current_list_price - c.current_sale_price) / c.current_list_price * 100
      end as list_vs_sale_discount_pct
    , case when c.current_list_price is not null and c.current_list_price <> 0
        then (c.current_list_price - c.current_b2b_price) / c.current_list_price * 100
      end as b2b_vs_list_discount_pct

from {{ ref('v_product_price_current') }} c
left join {{ ref('dim_product') }} d
    on d.product_key = c.product_key
    and d.version_number = 1
