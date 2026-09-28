{{ config(materialized = 'view') }}

select

      product_id
    , max(product_key) as product_key
    , max(sku) as sku

    , max(case when cost_type = 'STANDARD' then standard_cost_unit end) as current_standard_cost_unit
    , max(case when cost_type = 'STANDARD' then standard_cost_unit_usd end) as current_standard_cost_unit_usd
    , max(case when cost_type = 'STANDARD' then effective_date end) as standard_cost_effective_date

    , max(case when cost_type = 'LANDED' then landed_cost_unit end) as current_landed_cost_unit
    , max(case when cost_type = 'LANDED' then effective_date end) as landed_cost_effective_date

    , max(case when cost_type = 'VENDOR' then vendor_cost_unit end) as current_vendor_cost_unit
    , max(case when cost_type = 'VENDOR' then effective_date end) as vendor_cost_effective_date

    , max(case when cost_type = 'PLM_ESTIMATED' then plm_estimated_cost_unit end) as current_plm_estimated_cost_unit
    , max(case when cost_type = 'PLM_ESTIMATED' then effective_date end) as plm_cost_effective_date

    , max(cost_currency_code) as cost_currency_code

from {{ ref('fact_product_cost') }}
where is_current
group by product_id
