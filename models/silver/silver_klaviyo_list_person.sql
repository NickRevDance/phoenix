{{ config(materialized = 'table') }}

SELECT
      b.list_id
    , b.person_id
    , b.joined_group_at
    , b._fivetran_synced
FROM {{ ref('bronze_klaviyo_list_person') }} b
WHERE NOT COALESCE(b._fivetran_deleted, false)
