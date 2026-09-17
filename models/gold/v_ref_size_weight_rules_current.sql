{{ config(materialized = 'view') }}

select *
from {{ ref('ref_size_weight_rules') }}
where is_active = 1
