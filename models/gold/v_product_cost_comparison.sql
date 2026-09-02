{{ config(materialized = 'view') }}

select

      c.product_key
    , c.product_id
    , c.sku
    , d.product_group
    , d.product_supplier

    , c.current_standard_cost_unit as standard_cost_unit
    , c.current_landed_cost_unit as landed_cost_unit
    , c.current_vendor_cost_unit as vendor_cost_unit
    , c.current_plm_estimated_cost_unit as plm_estimated_cost_unit
    , c.cost_currency_code

    , c.current_landed_cost_unit - c.current_standard_cost_unit as standard_vs_landed_variance
    , c.current_vendor_cost_unit - c.current_standard_cost_unit as standard_vs_vendor_variance
    , c.current_plm_estimated_cost_unit - c.current_standard_cost_unit as plm_vs_actual_variance

from {{ ref('v_product_cost_current') }} c
left join {{ ref('dim_product') }} d
    on d.product_key = c.product_key
    and d.version_number = 1
