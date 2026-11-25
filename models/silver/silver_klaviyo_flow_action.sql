{{ config(materialized = 'table') }}

SELECT
      b.id
    , b.action_type
    , b.status
    , b.flow_id
    , b.tracking_options_is_tracking_opens
    , b.tracking_options_is_tracking_clicks
    , b.tracking_options_add_utm
    , b.send_options_use_smart_sending
    , b.send_options_is_transactional
    , b.render_options_shorten_links
    , b.render_options_add_org_prefix
    , b.render_options_add_info_link
    , b.render_options_add_opt_out_language
    , b.render_options_include_contact_card
    , b.created
    , b.updated
    , b._fivetran_synced
FROM {{ ref('bronze_klaviyo_flow_action') }} b
WHERE NOT COALESCE(b._fivetran_deleted, false)
