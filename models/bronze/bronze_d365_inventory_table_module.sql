{{ config(materialized = 'view') }}

SELECT
    *
FROM
    {{ source('byod', 'd365_inventory_table_module') }}
