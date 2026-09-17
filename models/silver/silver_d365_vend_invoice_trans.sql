{{ config(materialized = 'table') }}

SELECT

      PURCHID
    , PURCHASELINELINENUMBER            -- FK back to PurchLine.LINENUMBER; 0 = non-line-specific charge (freight/misc), not tied to a PO line
    , ITEMID
    , INVENTDIMID
    , QTY
    , LINEAMOUNT
    , INVOICEID
    , INVOICEDATE
    , RECID

FROM
    {{ ref('bronze_d365_vend_invoice_trans') }}
