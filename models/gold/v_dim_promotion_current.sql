{{ config(materialized = 'view', schema = 'shared_gold') }}

select
    dp.* except
        (
            row_hash
            , effective_start_datetime
            , effective_end_datetime
            , version_number
            , is_current_row
            , etl_update_datetime
        )
from {{ ref('dim_promotion') }} dp
where dp.is_current_row = 1
