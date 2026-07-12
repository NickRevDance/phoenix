{{ config(materialized = 'table') }}

SELECT
    ItemID
    , InventDimID
    , INVENTSIZEID
    , INVENTCOLORID
    , INVENTLOCATIONID
    , inventsiteid
    , SYNCSTARTDATETIME
    , AVAILPHYSICAL
    , AVAILORDERED
    , closed
    , closedqty
    , RESERVPHYSICAL
FROM
    {{ ref('bronze_byod_inventory_sum') }}