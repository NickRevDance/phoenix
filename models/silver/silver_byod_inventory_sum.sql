{{ config(materialized = 'table') }}

SELECT
    ItemID
    , InventDimID
    , AVAILPHYSICAL
    , AVAILORDERED
    , closed
    , closedqty
    , RESERVPHYSICAL
    , INVENTLOCATIONID
    , inventsiteid
    , SYNCSTARTDATETIME
FROM
    {{ ref('bronze_byod_inventory_sum') }}