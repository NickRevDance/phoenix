{{ config(materialized = 'view') }}

SELECT
    *
FROM
    {{ source('byod', 'd365_item_barcode') }}
