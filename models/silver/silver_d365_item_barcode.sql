{{ config(materialized = 'table') }}

SELECT
    {{dbt_utils.generate_surrogate_key(['InventDimID', 'ItemID']) }} AS barcode_id
    , *
FROM
    {{ ref('bronze_d365_item_barcode') }}
WHERE
    UnitID = 'EA'
    AND BarcodeSetupID = 'Code 39'