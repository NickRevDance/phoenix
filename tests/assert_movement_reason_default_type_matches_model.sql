{{ config(severity = 'warn') }}

-- EDW-7 / spec 8.5: every included REF_MOVEMENT_REASON row's default_movement_type matches the
-- movement type the movement model gives that code. Code 0 splits on sign, so it may read RETURN too.
-- A row here is spec drift between the reference table and the model, not a data error.
select
      f.movement_reason_code
    , f.movement_type
    , r.default_movement_type
    , count(*) as movement_rows
from {{ ref('fact_inventory_movement') }} f
inner join {{ ref('v_ref_movement_reason_current') }} r
    on r.movement_reason_code = f.movement_reason_code
where r.is_included_flag
  and f.movement_type <> r.default_movement_type
  and not (r.movement_reason_code = '0' and f.movement_type = 'RETURN')
group by 1, 2, 3
