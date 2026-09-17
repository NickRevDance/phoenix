-- EDW-48 acceptance criteria: every setting has an active ALL row (sub-group overrides are additive, not a replacement for the default).
select distinct setting_name
from {{ ref('ref_inventory_quality_thresholds') }}
where setting_name not in (
    select setting_name
    from {{ ref('ref_inventory_quality_thresholds') }}
    where is_active = 1 and scope_product_subgroup = 'ALL'
)
