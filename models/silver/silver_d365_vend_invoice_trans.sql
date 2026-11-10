{{ config(materialized = 'table') }}

SELECT

      PURCHID
    , INVENTTRANSID                     -- PurchLine.INVENTTRANSID: the PO line join key (EDW-68)
    , PURCHASELINELINENUMBER            -- line position at posting, not the current PurchLine.LINENUMBER; 0 = header-level charge, not tied to a PO line
    , ITEMID
    , INVENTDIMID
    , QTY
    , LINEAMOUNT
    , INVOICEID
    , INVOICEDATE
    , RECID

FROM
    {{ ref('bronze_d365_vend_invoice_trans') }}
