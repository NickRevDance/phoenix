{{ config(materialized = 'table') }}

SELECT

      ITEMID
    , INVENTDIMID
    , GITID
    , TRANSREFID
    , TRANSTYPE
    , STATUS
    , QTY
    , REMAINQTY
    , GITDATE
    , EXPECTEDDATE

FROM
    {{ ref('bronze_d365_itm_goods_in_transit_order') }}
WHERE
    STATUS = 1  -- in transit, not yet received -- confirmed live 2026-09-10: 100% of these rows (952/952) match a real PO via TRANSREFID = PurchTable.PURCHID (TRANSTYPE is constant 3, zero matches against InventTransferTable) -- this table is vendor-PO goods-in-transit only
