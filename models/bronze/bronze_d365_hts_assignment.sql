{{ config(materialized = 'view') }}

SELECT
    *
FROM
    {{ source('byod', 'd365_hts_assignment') }}
