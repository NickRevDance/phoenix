{{ config(materialized = 'view') }}

select
    r.* except
        (
            record_source_table
            , row_hash
            , effective_start_datetime
            , effective_end_datetime
            , version_number
            , is_current_row
            , etl_insert_datetime
            , etl_update_datetime
        )
from {{ ref('ref_movement_reason') }} r
where r.is_current_row = 1
