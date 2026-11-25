{{ config(
    materialized = 'table',
    liquid_clustered_by = ['datetime', 'metric_id']
) }}

-- Event properties land as property_* columns (Fivetran unpacked mode). Fivetran widens a property's type when
-- new values don't fit (e.g. bigint to string), which an incremental table can't follow, so this rebuilds in full.

SELECT
      b.* EXCEPT (b._fivetran_deleted)
    , b.property_attribution:relationships['attributed-event'].data.id::string AS attributed_event_id
    , b.property_attribution:relationships.campaign.data.id::string            AS attributed_campaign_id
    , b.property_attribution:relationships.flow.data.id::string                AS attributed_flow_id
    , b.property_attribution:relationships['flow-message'].data.id::string     AS attributed_flow_message_id
FROM {{ ref('bronze_klaviyo_event') }} b
WHERE NOT COALESCE(b._fivetran_deleted, false)
