-- EDW-177: the facts that keep source-deleted rows carry the same delete mark as silver.

select 'fact_order_line' as model, o.order_line_key as fact_key, o.is_source_deleted_flag, s.is_deleted
from {{ ref('fact_order_line') }} o
inner join {{ ref('silver_d365_sales_line') }} s
    on o.order_line_key = xxhash64(s.REC, 'D365')
where not (o.is_source_deleted_flag <=> (s.is_deleted = 1))

union all

select 'fact_inventory_movement', m.inventory_movement_key, m.is_source_deleted_flag, t.is_deleted
from {{ ref('fact_inventory_movement') }} m
inner join {{ ref('silver_d365_inventory_trans') }} t
    on m.inventory_movement_key = xxhash64(t.RECID)
where not (m.is_source_deleted_flag <=> (t.is_deleted = 1))
