with distinct_profiles as (

    -- customer_segment_id is computed once, in silver_stage_customer_segment_profile.sql
    -- (same sha2 formula), and just carried through/deduped here -- not recomputed --
    -- so dim_customer.sql's segment_map join (profile.customer_segment_id =
    -- this table's customer_segment_id) always resolves against the same values.
    select distinct
          customer_segment_id
        , customer_type
        , customer_segment
        , lifecycle_stage
        , customer_tier
        , loyalty_tier
        , is_dso_member_flag
        , dso_membership_status
        , loyalty_enrolled_flag
        , purchase_frequency_band
        , avg_order_value_band
        , channel_preference
    from {{ ref('silver_stage_customer_segment_profile') }}

),

final as (

    select

          customer_segment_id

        , customer_type
        , customer_segment
        , lifecycle_stage
        , customer_tier
        , loyalty_tier
        , is_dso_member_flag
        , dso_membership_status
        , loyalty_enrolled_flag
        , purchase_frequency_band
        , avg_order_value_band
        , channel_preference

        , concat_ws(' | ', customer_type, lifecycle_stage, customer_tier) as segment_display_name  -- per spec section 9 example format

        , sha2(
            concat_ws('||',
                coalesce(cast(loyalty_enrolled_flag as string), ''),
                coalesce(dso_membership_status, '')
            ), 256
          ) as profile_change_hash  -- hashes the Type 1 attributes that can change in place under a fixed customer_segment_id

        , 'silver_stage_dim_customer_segment' as record_source_table
        , current_timestamp() as etl_insert_datetime

    from distinct_profiles

)

select * from final
