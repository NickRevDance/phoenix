{{ config(materialized = 'view') }}

SELECT
    *
FROM
    {{ source('byod', 'd365_inventory_transfer_line') }}
