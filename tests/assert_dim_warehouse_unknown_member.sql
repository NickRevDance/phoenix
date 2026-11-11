{{ config(severity = 'warn') }}

-- EDW-90 (DIM_WAREHOUSE spec 3.7): exactly one -1 Unknown member, current, and present in the current view.
with dim as (

    select count(*) as n
    from {{ ref('dim_warehouse') }}
    where warehouse_key = {{ unknown_member_key() }}
      and warehouse_id = 'UNKNOWN'
      and warehouse_type = 'Reserved'
      and version_number = 1
      and is_current_row = 1

),

current_view as (

    select count(*) as n
    from {{ ref('v_dim_warehouse_current') }}
    where warehouse_key = {{ unknown_member_key() }}

)

select d.n as dim_rows, v.n as current_view_rows
from dim d
cross join current_view v
where d.n <> 1 or v.n <> 1
