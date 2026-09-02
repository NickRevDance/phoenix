{{ config(materialized = 'table') }}

SELECT
    md5(concat_ws('|',lower(trim(i_loc.DATAAREAID)), lower(trim(i_loc.INVENTLOCATIONID)))) as location_key
    , i_loc.*
FROM
    {{ref("bronze_d365_inventory_location")}} i_loc