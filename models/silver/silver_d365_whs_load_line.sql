{{ config(materialized = 'table') }}

-- Full rebuild each run: open shipments are re-planned and deleted in D365, so a merge would keep stale rows.
-- One row per WMS load line. A sales load line is one sales line (INVENTTRANSID) on one shipment (SHIPMENTID), the shipment-line grain of FACT_SHIPMENT.

{% if empty_extract_guard(ref('bronze_d365_whs_load_line'), 1) %}

SELECT
    t.*
FROM
    {{ this }} t

{% else %}

SELECT
      ll.RECID
    , ll.REC
    , ll.SHIPMENTID
    , ll.LOADID
    , ll.ORDERNUM
    , ll.INVENTTRANSID
    , ll.INVENTTRANSTYPE
    , ll.ITEMID
    , ll.INVENTDIMID
    , ll.QTY
    , ll.INVENTQTY
    , ll.PICKEDQTY
    , ll.PACKINGQTY
    , ll.WORKCREATEDQTY
    , ll.UOM
    , ll.ITEMNETWEIGHT
    , ll.ITEMTAREWEIGHT
    , ll.INVALID
    , ll.LOADDIRECTION
    , ll.LOADREADYTOSHIPUTCDATETIME
    , ll.LOADCLOSEDUTCDATETIME
    , ll.CREATEDDATE
    , ll.MODIFIEDDATE
    , ll.DATAAREAID
    , ll.SYNCSTARTDATETIME
FROM
    {{ ref('bronze_d365_whs_load_line') }} ll

{% endif %}
