{{ config(materialized = 'table') }}

SELECT
     ItemID
    ,Density
    ,UnitVolume
    ,ModifiedDate
FROM
    {{ ref('bronze_d365_inventory_item') }}