{{ config(materialized = 'table') }}

SELECT
      b.segment_id
    , b.person_id
    , b._fivetran_synced
FROM {{ ref('bronze_klaviyo_segment_person') }} b
WHERE NOT COALESCE(b._fivetran_deleted, false)
