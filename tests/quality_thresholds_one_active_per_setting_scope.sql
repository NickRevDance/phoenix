-- EDW-48 acceptance criteria: exactly one active row per setting_name + scope_product_subgroup.
select
      setting_name, scope_product_subgroup, count(*) as active_row_count
from {{ ref('ref_inventory_quality_thresholds') }}
where is_active = 1
group by setting_name, scope_product_subgroup
having count(*) > 1
