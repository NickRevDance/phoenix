{{ config(materialized = 'table') }}

with origin_base as (

    select

          s.sales_origin_id
        , s.origin_description
        , s.channel_code
        , s.mapping_confidence
        , s.source_system
        , s.is_active_flag
        , s.mapping_notes

    from {{ ref('silver_stage_ref_sales_origin_map') }} s

),

final as (

    select

          b.sales_origin_id
        , b.origin_description
        , b.channel_code
        , b.mapping_confidence
        , b.source_system
        , b.is_active_flag
        , cast(null as boolean) as is_external_revenue  -- Source once available: manual seed -- Phase 2 per spec, not yet classified
        , b.mapping_notes

        , 'sales_origin_map' as record_source
        , current_timestamp() as etl_insert_datetime
        , current_timestamp() as etl_update_datetime

    from origin_base b

)

select * from final
