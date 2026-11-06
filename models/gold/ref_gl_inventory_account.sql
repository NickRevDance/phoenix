{{ config(materialized = 'table') }}

-- REF_GL_INVENTORY_ACCOUNT (Inventory spec 5.10; EDW-183 step 2). Reads the seed directly and
-- casts here (no silver stage model): a BI-maintained classification with no source-system
-- input, the same way ref_return_reason_category reads its seed.

with seed_typed as (

    select

          trim(s.main_account_id) as main_account_id
        , upper(trim(s.gl_bucket)) as gl_bucket
        , trim(s.gl_bucket_description) as gl_bucket_description
        , lower(trim(s.is_tied_to_gold)) = 'true' as is_tied_to_gold_flag
        , cast(s.bucket_sort_order as int) as bucket_sort_order
        , nullif(trim(s.classified_by), '') as classified_by
        , cast(s.classified_date as date) as classified_date
        , nullif(trim(s.notes), '') as notes

    from {{ ref('gl_inventory_account') }} s

),

final as (

    select

          t.main_account_id
        , t.gl_bucket
        , t.gl_bucket_description
        , t.is_tied_to_gold_flag
        , t.bucket_sort_order
        , t.classified_by
        , t.classified_date
        , t.notes
        , 'gl_inventory_account' as record_source
        , current_timestamp() as etl_insert_datetime
        , current_timestamp() as etl_update_datetime

    from seed_typed t

)

select * from final