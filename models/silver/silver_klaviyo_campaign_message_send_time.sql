{{ config(materialized = 'table') }}

SELECT
      b.campaign_message_id
    , b.datetime
    , b.is_local
    , b._fivetran_synced
FROM {{ ref('bronze_klaviyo_campaign_message_send_time') }} b
WHERE NOT COALESCE(b._fivetran_deleted, false)
