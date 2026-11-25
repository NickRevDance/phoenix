{{ config(materialized = 'view') }}

SELECT
    s.*
FROM
    {{ source('klaviyo', 'person') }} s
