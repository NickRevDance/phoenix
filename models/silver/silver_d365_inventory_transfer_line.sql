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

FROM
    {{ ref('bronze_d365_inventory_transfer_line') }}
-- MODIFIEDDATE removed 2026-09-11: Rev_InventTransferLineStaging has no such column
-- (confirmed via DESCRIBE TABLE) -- only SYNCSTARTDATETIME, same as inventory_trans_origin.
-- No filter needed: 0 rows in the source as of 2026-09-10 (no live inter-warehouse transfer activity).
-- In-transit selection (shipped but not yet received) happens in the gold aggregation, same pattern as
-- silver_d365_itm_goods_in_transit_order.
