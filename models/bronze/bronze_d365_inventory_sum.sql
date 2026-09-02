{{ config(materialized = 'view') }}

SELECT
    *
FROM
    {{ source('byod', 'inventory_sum') }}