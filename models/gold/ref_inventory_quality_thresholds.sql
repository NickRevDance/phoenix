{{ config(materialized = 'table') }}

with quality_thresholds_base as (

    select

          s.setting_name
        , s.scope_product_subgroup
        , s.setting_value
        , s.setting_type
        , s.is_active
        , s.effective_start_date
        , s.effective_end_date
        , s.notes

    from {{ ref('silver_stage_ref_inventory_quality_thresholds') }} s

),

final as (

    select

          {{ generate_surrogate_key(['b.setting_name', 'b.scope_product_subgroup']) }} as threshold_key  -- stable per setting+scope, not per version

        , b.setting_name
        , b.scope_product_subgroup
        , b.setting_value
        , b.setting_type

        , b.is_active
        , b.effective_start_date
        , b.effective_end_date
        , {{ scd2_version_number('b.setting_name, b.scope_product_subgroup', order_by='b.effective_start_date') }} as version_number

        , b.notes
        , 'inventory_quality_thresholds_seed' as record_source
        , current_timestamp() as etl_insert_datetime
        , current_timestamp() as etl_update_datetime

        , {{ generate_row_hash([
              "coalesce(cast(b.setting_value as string), '')",
              "coalesce(b.setting_type, '')",
              "coalesce(cast(b.is_active as string), '')",
              "coalesce(cast(b.effective_end_date as string), '')"
          ]) }} as row_hash

    from quality_thresholds_base b

)

select * from final
