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
    {{ref("bronze_byod_inventory_dim")}}
