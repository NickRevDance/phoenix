SELECT
    InventDimID
    , inventsiteid
    , INVENTLOCATIONID
    , WMSLOCATIONID
    , InventBatchId
    , InventSerialId
    , INVENTSIZEID
    , INVENTCOLORID
    , INVENTSTATUSID
FROM
    {{ref("bronze_d365_inventory_dim")}}
