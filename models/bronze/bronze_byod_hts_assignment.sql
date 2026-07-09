{{ config(materialized = 'view') }}

SELECT
    *
FROM
    {{ source('byod', 'hts_assignment') }}