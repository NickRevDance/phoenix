{{ config(materialized = 'view') }}

SELECT
    src.*
FROM
    {{ source('byod', 'd365_whs_load_line') }} src
