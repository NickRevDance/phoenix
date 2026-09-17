{{ config(materialized = 'table') }}

with size_weight_rules_base as (

    select

          s.rule_id
        , s.priority
        , s.product_group
        , s.product_subgroup
        , s.gender
        , s.adult_child
        , s.style
        , s.brand
        , s.genre
        , s.age_look
        , s.size
        , s.size_weight
        , s.size_rank
        , s.is_core_size
        , s.size_system
        , s.size_sort_order
        , s.is_active
        , s.effective_start_date
        , s.effective_end_date
        , s.notes

    from {{ ref('silver_stage_ref_size_weight_rules') }} s

),

final as (

    select

          {{ generate_surrogate_key(['b.rule_id', 'b.effective_start_date']) }} as size_weight_rule_key  -- version-distinct key, matching ref_sla_target's pattern (natural key + effective_start_date)

        , b.rule_id
        , b.priority
        , b.product_group
        , b.product_subgroup
        , b.gender
        , b.adult_child
        , b.style
        , b.brand
        , b.genre
        , b.age_look
        , b.size
        , b.size_weight
        , b.size_rank
        , b.is_core_size
        , b.size_system
        , b.size_sort_order

        , b.is_active
        , b.effective_start_date
        , b.effective_end_date
        , b.notes
        , 'size_weight_rules_seed' as record_source
        , current_timestamp() as etl_insert_datetime
        , current_timestamp() as etl_update_datetime

    from size_weight_rules_base b

)

select * from final
