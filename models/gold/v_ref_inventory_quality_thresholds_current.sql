{{ config(materialized = 'view') }}

select *
from {{ ref('ref_inventory_quality_thresholds') }}
where is_active = 1
