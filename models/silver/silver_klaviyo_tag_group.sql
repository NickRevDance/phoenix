{{ config(materialized = 'table') }}

SELECT
      b.id
    , b.name
    , b.exclusive
    , b.`default`
    , b._fivetran_synced
FROM {{ ref('bronze_klaviyo_tag_group') }} b
WHERE NOT COALESCE(b._fivetran_deleted, false)
