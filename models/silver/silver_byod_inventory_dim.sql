SELECT
    InventDimID
    , inventsiteid
    , INVENTLOCATIONID
    , WMSLOCATIONID
    , InventBatchId
    , InventSerialId
FROM
    {{ref("bronze_byod_inventory_dim")}}