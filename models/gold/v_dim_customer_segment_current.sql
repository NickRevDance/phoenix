{{ config(materialized = 'view', schema = 'marketing_gold') }}

select
    dcs.* EXCEPT
        (
            profile_change_hash
            , row_hash
            , effective_start_datetime
            , effective_end_datetime
            , version_number
            , is_current_row
            , etl_update_datetime
        )
from {{ ref('dim_customer_segment') }} dcs
where is_current_row = 1
