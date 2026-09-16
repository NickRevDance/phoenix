{{ config(materialized = 'table') }}

with origin_base as (

    select

          s.sales_origin_id
        , s.origin_description
        , s.channel_code
        , s.mapping_confidence
        , s.source_system
        , s.is_active_flag
        , s.first_observed_date
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
        , b.first_observed_date
        , cast(null as boolean) as is_external_revenue  -- Source once available: manual seed -- Phase 2 per spec, not yet classified
        , b.mapping_notes

        , 'sales_origin_map' as record_source
        , current_timestamp() as etl_insert_datetime
        , current_timestamp() as etl_update_datetime
        , sha2(
            concat_ws('||',
                coalesce(b.origin_description, ''),
                coalesce(b.channel_code, ''),
                coalesce(b.mapping_confidence, ''),
                coalesce(b.source_system, ''),
                coalesce(cast(b.is_active_flag as string), ''),
                coalesce(cast(b.first_observed_date as string), '')
            ), 256
          ) as row_hash  -- v1.1 new. Same inline sha2/concat_ws pattern as dim_sales_channel -- no shared EDW-8 macro exists in this project yet.

    from origin_base b

)

select * from final
