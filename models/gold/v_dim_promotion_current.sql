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
    , case
        when (dp.promotion_end_date is null or dp.promotion_end_date >= current_date())
         and (dp.promotion_start_date is null or dp.promotion_start_date <= current_date())
        then true else false
      end as is_active_flag  -- date-relative, so derived here rather than in the change hash (would cut a new SCD2 version every time a window opens/closes)
from {{ ref('dim_promotion') }} dp
where dp.is_current_row = 1
