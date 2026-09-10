{{ config(materialized = 'view') }}

SELECT
    *
FROM
    {{ source('byod', 'd365_inventory_on_hand') }}
