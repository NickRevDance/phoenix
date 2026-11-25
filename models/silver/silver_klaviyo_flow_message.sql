{{ config(materialized = 'table') }}

SELECT
      b.id
    , b.name
    , b.channel
    , b.flow_action_id
    , b.template_id
    , b.created
    , b.updated
    , b.content_subject
    , b.content_preview_text
    , b.content_from_email
    , b.content_from_label
    , b.content_reply_to_email
    , b.content_cc_email
    , b.content_bcc_email
    , b._fivetran_synced
FROM {{ ref('bronze_klaviyo_flow_message') }} b
WHERE NOT COALESCE(b._fivetran_deleted, false)
