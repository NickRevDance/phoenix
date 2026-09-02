{{ config(materialized = 'table') }}

SELECT
     ItemID
    ,LineDisc
    ,ModuleType
    ,UnderDeliveryPCT
    ,ModifiedDate
FROM
    {{ ref('bronze_d365_inventory_module') }}
WHERE
    ModuleType = 2