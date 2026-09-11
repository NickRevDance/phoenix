{{ config(materialized = 'view') }}

SELECT
    *
FROM
    {{ source('byod', 'd365_itm_goods_in_transit_order') }}
