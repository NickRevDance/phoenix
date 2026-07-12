{{ config(materialized = 'view') }}

SELECT
    *
FROM
    {{ source('byod', 'inventory_on_hand') }}