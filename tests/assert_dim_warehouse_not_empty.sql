-- Fails when dim_warehouse holds no sourced warehouse (an empty BYOD InventLocation read). The -1 member doesn't count.
select
    count(*) as row_count
from {{ ref('dim_warehouse') }}
where warehouse_key <> {{ unknown_member_key() }}
having count(*) = 0
