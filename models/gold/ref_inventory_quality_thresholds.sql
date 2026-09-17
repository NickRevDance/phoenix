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

          {{ generate_surrogate_key(['b.setting_name', 'b.scope_product_subgroup', 'b.effective_start_date']) }} as threshold_key  -- version-distinct key, matching ref_sla_target's pattern (natural key + effective_start_date)

        , b.setting_name
        , b.scope_product_subgroup
        , b.setting_value
        , b.setting_type

        , b.is_active
        , b.effective_start_date
        , b.effective_end_date
        , b.notes
        , 'inventory_quality_thresholds_seed' as record_source
        , current_timestamp() as etl_insert_datetime
        , current_timestamp() as etl_update_datetime

    from quality_thresholds_base b

)

select * from final
