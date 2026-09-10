{{ config(materialized = 'view') }}

SELECT
    *
FROM
    {{ source('byod', 'd365_warehouse_location') }}
