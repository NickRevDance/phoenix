{{ config(materialized = 'view') }}

SELECT
    *
FROM
    {{ source('byod', 'itm_goods_in_transit_order') }}
