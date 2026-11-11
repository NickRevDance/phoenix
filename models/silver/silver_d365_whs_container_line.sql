{{ config(materialized = 'table') }}

-- Full rebuild each run: open shipments are re-planned and deleted in D365, so a merge would keep stale rows.
-- One row per load line packed into a container. LOADLINE = silver_d365_whs_load_line.RECID.

{% if empty_extract_guard(ref('bronze_d365_whs_container_line'), 1) %}

SELECT
    t.*
FROM
    {{ this }} t

{% else %}

SELECT
      cl.REC
    , cl.CONTAINERID
    , cl.SHIPMENTID
    , cl.LOADLINE
    , cl.ITEMID
    , cl.INVENTDIMID
    , cl.QTY
    , cl.UNITID
    , cl.CAPTUREDWEIGHT
    , cl.MODIFIEDDATE
    , cl.DATAAREAID
    , cl.SYNCSTARTDATETIME
FROM
    {{ ref('bronze_d365_whs_container_line') }} cl

{% endif %}
