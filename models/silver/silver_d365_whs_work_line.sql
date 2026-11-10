{{ config(
    materialized = 'incremental',
    unique_key = 'REC',
    incremental_strategy = 'merge',
    on_schema_change = 'sync_all_columns',
    liquid_clustered_by = ['INVENTTRANSID']
) }}

-- One row per WMS work line, all work types. The export carries REC (no RECID); REC is unique.
-- Sales-order picks: WORKTYPE 1, WHSWORKTEMPLATELINE_WORKTRANSTYPE 2, WORKSTATUS 4 (closed).
-- Outbound work picks twice (storage to PACKING, then PACKING out), so picked qty counts only picks
-- whose WMSLOCATIONID is not PACKING.
SELECT
      wl.REC
    , wl.WORKID
    , wl.LINENUM
    , wl.WORKTYPE
    , wl.WHSWORKTEMPLATELINE_WORKTRANSTYPE
    , wl.WHSWORKTEMPLATELINE_WORKTEMPLATECODE
    , wl.WORKCLASSID
    , wl.WORKSTATUS
    , wl.ORDERNUM
    , wl.INVENTTRANSID
    , wl.ITEMID
    , wl.INVENTDIMID
    , wl.WMSLOCATIONID
    , wl.QTYWORK
    , wl.QTYREMAIN
    , wl.INVENTQTYWORK
    , wl.INVENTQTYREMAIN
    , wl.UNITID
    , wl.LOADID
    , wl.SHIPMENTID
    , wl.CONTAINERID
    , wl.USERID
    , wl.SKIPPED
    , wl.WORKINPROCESSUTCDATETIME
    , wl.WORKCLOSEDUTCDATETIME
    , wl.DATAAREAID
    , wl.CREATEDDATE
    , wl.MODIFIEDDATE
    , wl.SYNCSTARTDATETIME
FROM
    {{ ref('bronze_d365_whs_work_line') }} wl

{% if is_incremental() %}
WHERE wl.SYNCSTARTDATETIME > (SELECT COALESCE(MAX(t.SYNCSTARTDATETIME), TIMESTAMP('1900-01-01')) FROM {{ this }} t) - INTERVAL 2 DAYS
{% endif %}
