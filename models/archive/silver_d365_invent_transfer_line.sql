{{ config(materialized = 'table') }}

SELECT

      ITEMID
    , INVENTDIMID
    , INVENTDIMIDTO_RU
    , TRANSFERID
    , QTYSHIPPED
    , QTYRECEIVED
    , QTYREMAINRECEIVE
    , SHIPDATE
    , RECEIVEDATE
    , MODIFIEDDATE

FROM
    {{ ref('bronze_d365_invent_transfer_line') }}
-- No filter needed: 0 rows in the source as of 2026-09-10 (no live inter-warehouse transfer activity).
-- In-transit selection (shipped but not yet received) happens in the gold aggregation, same pattern as
-- silver_d365_itm_goods_in_transit_order.
