{{ config(materialized = 'table') }}

SELECT
      b.id
    , b.form_type
    , b.ab_test_variation_name
    , b.status
    , b.created_at
    , b.updated_at
    , b.form_id
    , b._fivetran_synced
FROM {{ ref('bronze_klaviyo_form_version') }} b
WHERE NOT COALESCE(b._fivetran_deleted, false)
