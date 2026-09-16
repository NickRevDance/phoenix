{{ config(materialized = 'table') }}

with base as (

    select
          s.product_summary_class_key
        , s.brand
        , s.product_group
        , s.product_sub_group
        , s.summary_class
        , s.classification_owner
        , s.classified_date
        , s.notes

    from {{ ref('silver_stage_ref_product_summary_class') }} s

),

final as (

    select
          b.*
        , 'product_summary_class_map' as record_source
        , current_timestamp() as etl_insert_datetime
        , current_timestamp() as etl_update_datetime

    from base b

)

select * from final
