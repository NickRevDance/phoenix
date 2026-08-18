SELECT
    InventDimID
    , inventsiteid
    , INVENTLOCATIONID
    , WMSLOCATIONID
    , InventBatchId
    , InventSerialId
    , INVENTSIZEID
    , INVENTCOLORID
FROM
    {{ref("bronze_byod_inventory_dim")}}