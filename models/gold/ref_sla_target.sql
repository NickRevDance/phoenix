{{ config(materialized = 'table', schema = 'shared_gold') }}

with base as (

    select

          s.metric_code
        , s.metric_name
        , s.business_unit_code
        , s.scope_type
        , s.scope_code
        , s.comparison_operator
        , s.target_value
        , s.target_unit
        , s.goal_direction
        , s.is_monitor_only_flag
        , s.effective_from_date
        , s.effective_to_date
        , s.approved_by_role
        , s.approved_date
        , s.target_notes

    from {{ ref('silver_stage_ref_sla_target') }} s

),

final as (

    select

          {{ generate_surrogate_key(['b.metric_code', 'b.business_unit_code', 'b.scope_type', 'b.scope_code', 'b.effective_from_date']) }} as sla_target_key

        , b.metric_code
        , b.metric_name
        , b.business_unit_code
        , b.scope_type
        , b.scope_code
        , b.comparison_operator
        , b.target_value
        , b.target_unit
        , b.goal_direction
        , b.is_monitor_only_flag
        , b.effective_from_date
        , b.effective_to_date
        , case when b.effective_to_date is null then true else false end as is_current_flag  -- derived, not seed-stored: see README
        , b.approved_by_role
        , b.approved_date
        , b.target_notes

        , 'ref_sla_target' as record_source
        , current_timestamp() as etl_insert_datetime
        , current_timestamp() as etl_update_datetime

    from base b

)

select * from final
