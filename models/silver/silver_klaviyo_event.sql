{{ config(
    materialized = 'incremental',
    unique_key = 'id',
    incremental_strategy = 'merge',
    on_schema_change = 'sync_all_columns',
    liquid_clustered_by = ['datetime', 'metric_id']
) }}

-- Event properties land as property_* columns (Fivetran unpacked mode) and are carried through as they appear.

SELECT
      b.* EXCEPT (b._fivetran_deleted)
    , b.property_attribution:relationships['attributed-event'].data.id::string AS attributed_event_id
    , b.property_attribution:relationships.campaign.data.id::string            AS attributed_campaign_id
    , b.property_attribution:relationships.flow.data.id::string                AS attributed_flow_id
    , b.property_attribution:relationships['flow-message'].data.id::string     AS attributed_flow_message_id
FROM {{ ref('bronze_klaviyo_event') }} b
WHERE NOT COALESCE(b._fivetran_deleted, false)
{% if is_incremental() %}
  AND b._fivetran_synced > (SELECT MAX(t._fivetran_synced) FROM {{ this }} t)
{% endif %}
