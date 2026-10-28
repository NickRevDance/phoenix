-- EDW-177: every silver row carries a 0/1 delete mark, with a detection time only when marked.

select 'silver_d365_sales_line' as model, cast(s.REC as bigint) as rec_id, s.is_deleted, s.deleted_detected_datetime
from {{ ref('silver_d365_sales_line') }} s
where s.is_deleted is null
   or s.is_deleted not in (0, 1)
   or (s.is_deleted = 1) <> (s.deleted_detected_datetime is not null)

union all

select 'silver_d365_sales_table', cast(h.REC as bigint), h.is_deleted, h.deleted_detected_datetime
from {{ ref('silver_d365_sales_table') }} h
where h.is_deleted is null
   or h.is_deleted not in (0, 1)
   or (h.is_deleted = 1) <> (h.deleted_detected_datetime is not null)

union all

select 'silver_d365_inventory_trans', cast(t.RECID as bigint), t.is_deleted, t.deleted_detected_datetime
from {{ ref('silver_d365_inventory_trans') }} t
where t.is_deleted is null
   or t.is_deleted not in (0, 1)
   or (t.is_deleted = 1) <> (t.deleted_detected_datetime is not null)
