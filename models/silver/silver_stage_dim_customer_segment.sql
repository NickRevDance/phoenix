with distinct_profiles as (

    select distinct
          customer_type
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

          sha2(
            concat_ws('||',
                coalesce(customer_type, ''),
                coalesce(customer_segment, ''),
                coalesce(lifecycle_stage, ''),
                coalesce(customer_tier, ''),
                coalesce(loyalty_tier, ''),
                coalesce(cast(is_dso_member_flag as string), ''),
                coalesce(purchase_frequency_band, ''),
                coalesce(avg_order_value_band, ''),
                coalesce(channel_preference, '')
            ), 256
          ) as customer_segment_id  -- business key per spec section 9 formula; dso_membership_status and loyalty_enrolled_flag excluded, they're Type 1 profile-completeness fields, not part of the combination

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
