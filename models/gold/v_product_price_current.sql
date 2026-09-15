{{ config(materialized = 'view') }}

-- v1.1 change (spec Section 9.1): pivoted by currency, one row per
-- product_key (variant), not one row per price_type. This is the shape
-- FACT_INVENTORY_SNAPSHOT_DAILY needs for retail_value_amount (EDW-49,
-- product_key + USD current row) and what Power BI imports as its price
-- lookup.

select

      f.product_key
    , max(f.product_id) as product_id
    , max(f.sku) as sku

    , max(case when f.price_currency_code = 'USD' then f.list_price end) as list_price_usd
    , max(case when f.price_currency_code = 'USD' then f.effective_date end) as list_price_usd_effective_date
    , max(case when f.price_currency_code = 'CAD' then f.list_price end) as list_price_cad
    , max(case when f.price_currency_code = 'CAD' then f.effective_date end) as list_price_cad_effective_date

    , cast(null as decimal(19,4)) as sale_price_usd  -- Phase 2
    , cast(null as decimal(19,4)) as sale_price_cad  -- Phase 2
    , cast(null as decimal(19,4)) as b2b_price_usd  -- Phase 2
    , cast(null as decimal(19,4)) as b2b_price_cad  -- Phase 2
    , cast(null as boolean) as is_on_sale_flag  -- Phase 2

    , max(d.product_group) as product_group
    , max(d.summary_class) as summary_class
    , max(d.product_supplier) as product_supplier

from {{ ref('fact_product_price') }} f
left join {{ ref('dim_product') }} d
    on d.product_key = f.product_key
    and d.version_number = 1
where f.is_current
group by f.product_key
