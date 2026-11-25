{{ config(materialized = 'table') }}

SELECT
      b.id
    , b.name
    , b.editor_type
    , b.html
    , b.text
    , b.created
    , b.updated
    , b._fivetran_synced
FROM {{ ref('bronze_klaviyo_email_template') }} b
WHERE NOT COALESCE(b._fivetran_deleted, false)
