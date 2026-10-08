{{ config(materialized = 'table', schema = 'marketing_gold') }}

select
    snap.*
    , cast(null as string) as scd_change_reason  -- no per-attribute diff computed yet, matches DIM_CUSTOMER/DIM_VENDOR precedent
    , cast(null as int) as segment_sort_order  -- Source once available: business-defined lifecycle/tier ranking -- Phase 2 per spec, no sort algorithm given
    , xxhash64(snap.customer_segment_id) as customer_segment_key
    , row_number() over (
        partition by snap.customer_segment_id
        order by snap.effective_start_datetime desc
    ) as version_number
    , {{ scd2_is_current_row() }} as is_current_row  -- EDW-135: closed (invalidated) segments are not current
from {{ ref('silver_snapshot_dim_customer_segment') }} snap
