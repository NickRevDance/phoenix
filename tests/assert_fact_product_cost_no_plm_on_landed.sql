-- EDW-94 (Decision Record A8): no LANDED row sources from the PLM estimate,
-- and every item with a PLM landed estimate has a PLM_ESTIMATED row carrying it.

select cast(f.product_cost_key as string) as key_value, f.product_id, 'plm_sourced_landed_row' as failure
from {{ ref('fact_product_cost') }} f
where f.cost_type = 'LANDED'
    and f.is_current
    and (f.source_system <> 'D365' or f.record_source_table = 'dim_product')

union all

select p.product_id as key_value, p.product_id, 'plm_estimate_without_plm_estimated_row' as failure
from {{ ref('dim_product') }} p
left join {{ ref('fact_product_cost') }} f
    on f.product_id = p.product_id
    and f.cost_type = 'PLM_ESTIMATED'
    and f.is_current
    and f.landed_cost_unit is not null
where p.version_number = 1
    and p.plm_estimated_landed_cost is not null
    and f.product_id is null
group by p.product_id
