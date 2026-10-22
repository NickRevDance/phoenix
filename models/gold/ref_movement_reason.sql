{{ config(materialized = 'table') }}

with versions as (

    select

          snap.* except (movement_reason_change_hash)
        , {{ scd2_version_number('snap.movement_reason_key') }} as version_number

    from {{ ref('silver_snapshot_ref_movement_reason') }} snap

),

final as (

    select

          v.movement_reason_key
        , v.movement_reason_code
        , v.reference_category_name
        , v.movement_reason_desc
        , v.default_movement_type
        , v.default_movement_subtype
        , v.is_included_flag
        , v.notes
        , v.source_system
        , v.record_source_table
        , v.effective_start_datetime
        , v.effective_end_datetime
        , v.version_number
        , {{ scd2_is_current_row('v.version_number', 'v.effective_end_datetime') }} as is_current_row
        , v.row_hash
        , v.effective_start_datetime as etl_insert_datetime
        , v.etl_update_datetime

    from versions v

)

select * from final
