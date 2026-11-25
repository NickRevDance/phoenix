{{ config(materialized = 'table') }}

SELECT
      b.id
    , b.campaign_id
    , b.template_id
    , b.label
    , b.channel
    , b.content_subject
    , b.content_preview_text
    , b.content_from_email
    , b.content_from_label
    , b.content_reply_to_email
    , b.content_cc_email
    , b.content_bcc_email
    , b.content_body
    , b.content_media_url
    , b.render_options_shorten_links
    , b.render_options_add_org_prefix
    , b.render_options_add_info_link
    , b.render_options_add_opt_out_language
    , b.render_options_include_contact_card
    , b.created
    , b.updated
    , b._fivetran_synced
FROM {{ ref('bronze_klaviyo_campaign_message') }} b
WHERE NOT COALESCE(b._fivetran_deleted, false)
