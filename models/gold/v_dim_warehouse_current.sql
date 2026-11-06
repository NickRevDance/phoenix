{{ config(materialized = 'view') }}

-- EDW-90: current version of each warehouse (is_current_row = 1: latest version with an open end),
-- so a warehouse invalidated out of the extract drops out. The -1 unknown member is included.

select
    dw.* except
        (
              effective_start_datetime
            , effective_end_datetime
            , is_current_row
            , version_number
            , scd_change_reason
            , warehouse_change_hash
            , row_hash
            , record_source_table
            , etl_update_datetime
        )
from {{ ref('dim_warehouse') }} dw
where dw.is_current_row = 1
