{{ config(materialized = 'view') }}

SELECT
    *
FROM
    {{ source('byod', 'warehouse_location') }}