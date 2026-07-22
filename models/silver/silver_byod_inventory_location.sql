{{ config(materialized = 'table') }}

SELECT
    md5(concat_ws('|',lower(trim(i_loc.DATAAREAID)), lower(trim(i_loc.INVENTLOCATIONID)))) as warehouse_key
    , i_loc.inventlocationid as warehouse_id
    , i_loc.*
FROM
    {{ref("bronze_byod_inventory_location")}} i_loc