{{ config(materialized = 'table') }}

-- Every in-transit row, open (STATUS 1) and received (STATUS 2). fact_inventory_snapshot_daily filters to STATUS = 1 itself;
-- fact_purchase_order reads both for received_qty and in_transit_qty (spec Open Decision 8).
SELECT

      g.ITEMID
    , g.INVENTDIMID
    , g.INVENTTRANSID
    , g.INVENTTRANSIDREF                  -- PurchLine.INVENTTRANSID of the PO line this row ships
    , g.GITID
    , g.TRANSREFID
    , g.TRANSTYPE
    , g.STATUS                            -- 1 in transit, 2 received
    , g.QTY
    , g.REMAINQTY
    , g.GITDATE
    , g.EXPECTEDDATE

FROM
    {{ ref('bronze_d365_itm_goods_in_transit_order') }} g
