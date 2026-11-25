{{ config(materialized = 'table') }}

SELECT
      b.id
    , b.name
    , b.status
    , b.archived
    , b.send_time
    , b.send_option_use_smart_sending
    , b.send_option_ignore_unsubscribes
    , b.send_strategy_method
    , b.send_strategy_datetime
    , b.send_strategy_options_is_local
    , b.send_strategy_options_send_past_recipients_immediately
    , b.send_strategy_options_static_datetime
    , b.send_strategy_options_static_is_local
    , b.send_strategy_options_static_send_past_recipients_immediately
    , b.send_strategy_options_throttled_datetime
    , b.send_strategy_options_throttled_throttle_percentage
    , b.send_strategy_options_sto_date
    , b.tracking_options_is_tracking_opens
    , b.tracking_options_is_tracking_clicks
    , b.tracking_options_is_add_utm
    , b.tracking_options_add_tracking_params
    , b.created
    , b.scheduled
    , b.updated
    , b._fivetran_synced
FROM {{ ref('bronze_klaviyo_campaign') }} b
WHERE NOT COALESCE(b._fivetran_deleted, false)
