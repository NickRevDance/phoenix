{{ config(materialized = 'view', schema = 'marketing_gold') }}

-- Spec section 8 also calls for DIM_COUNTRY and DIM_SALES_CHANNEL joins.
-- Neither is sourced on DIM_CUSTOMER yet (ship_to_country_key and
-- sales_channel_key are both still null placeholders), so those two
-- stay deferred. DIM_CUSTOMER_SEGMENT is joined below now that it exists.

SELECT
    dc.* EXCEPT
        (
            customer_change_hash
            , row_hash
            , effective_start_datetime
            , effective_end_datetime
            , version_number
            , is_current_row
            , etl_update_datetime
        )
    , seg.customer_segment
    , seg.lifecycle_stage
    , seg.customer_tier
    , seg.loyalty_tier
    , seg.purchase_frequency_band
    , seg.avg_order_value_band
    , seg.channel_preference
    , seg.segment_display_name
    , seg.segment_sort_order
    , datediff(current_date(), dc.account_created_date) as customer_age_days  -- spec section 8 computed field
FROM
    {{ref("dim_customer")}} dc
LEFT JOIN
    {{ref("v_dim_customer_segment_current")}} seg
    ON dc.customer_segment_key = seg.customer_segment_key
WHERE
    dc.version_number = 1
