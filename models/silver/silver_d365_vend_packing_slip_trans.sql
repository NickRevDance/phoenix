{{ config(materialized = 'table') }}

SELECT

      ORIGPURCHID          as PURCHID  -- FK back to PurchLine.PURCHID
    , INVENTTRANSID                     -- PurchLine.INVENTTRANSID: the PO line join key (EDW-68)
    , PURCHASELINELINENUMBER            -- line position at posting, not the current PurchLine.LINENUMBER
    , ITEMID
    , INVENTDIMID
    , QTY                                -- actual received qty, this receipt event
    , ORDERED
    , CANCELLEDQTY
    , REMAIN
    , REMAININVENT
    , PACKINGSLIPID
    , VENDPACKINGSLIPJOUR
    , INVENTDATE                         -- receipt date
    , DELIVERYDATE
    , RECID

FROM
    {{ ref('bronze_d365_vend_packing_slip_trans') }}
