{{ config(severity = 'warn') }}

-- DQ exception: a snapshot status with no REF_INVENTORY_STATUS row is scored as not sellable (spec 4.1). Last 7 native days.

select
      f.snapshot_date
    , f.inventory_status_code
    , count(*) as snapshot_rows
    , sum(f.available_qty) as available_qty

from {{ ref('fact_inventory_snapshot_daily') }} f
left join {{ ref('ref_inventory_status') }} st
    on f.inventory_status_code = st.inventory_status_code
   and st.is_current_row = 1
where f.record_source_table = {{ inventory_snapshot_branch_label('native') }}
  and f.snapshot_date >= (select date_sub(max(x.snapshot_date), 6) from {{ ref('fact_inventory_snapshot_daily') }} x)
  and st.inventory_status_code is null
group by f.snapshot_date, f.inventory_status_code
