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
    , PHYSICALINVENT
    , md5(
        concat_ws(
            '|'
            , InventDimID
        )
    ) as change_hash
FROM
    {{ ref('bronze_d365_inventory_sum') }}
