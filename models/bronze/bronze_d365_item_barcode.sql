{{ config(materialized = 'view') }}

SELECT
    *
FROM
    {{ source('byod', 'item_barcode') }}