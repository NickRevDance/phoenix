{{ config(materialized = 'table') }}

SELECT
      b.flow_action_id
    , b.name
    , b.value
    , b._fivetran_synced
FROM {{ ref('bronze_klaviyo_flow_action_tracking_utm_param') }} b
WHERE NOT COALESCE(b._fivetran_deleted, false)
