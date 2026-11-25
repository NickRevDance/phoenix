{{ config(materialized = 'view') }}

SELECT
    s.*
FROM
    {{ source('klaviyo', 'metric') }} s
