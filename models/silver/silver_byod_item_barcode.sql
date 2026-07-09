{{ config(materialized = 'table') }}

SELECT
    *
FROM
    {{ ref('bronze_byod_item_barcode') }}
WHERE
    UnitID = 'EA'
    AND BarcodeSetupID = 'Code 39'