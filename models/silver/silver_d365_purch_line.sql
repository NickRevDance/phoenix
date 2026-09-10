{{ config(materialized = 'table') }}

SELECT

      ITEMID
    , INVENTDIMID
    , PURCHID
    , PURCHSTATUS
    , REMAINPURCHPHYSICAL
    , PURCHQTY
    , VENDACCOUNT
    , CONFIRMEDDLV
    , MODIFIEDDATE

FROM
    {{ ref('bronze_d365_purch_line') }}
WHERE
    PURCHSTATUS = 1  -- Backorder (open, not yet fully received) -- confirmed live 2026-09-10: REMAINPURCHPHYSICAL = PURCHQTY exactly for this status, 0 for Received/Invoiced/Canceled (2/3/4)
