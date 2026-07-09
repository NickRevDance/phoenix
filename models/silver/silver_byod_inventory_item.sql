{{ config(materialized = 'table') }}

SELECT
     ItemID
    ,Density
    ,UnitVolume
    ,ModifiedDate
FROM
    {{ ref('bronze_byod_inventory_item') }}