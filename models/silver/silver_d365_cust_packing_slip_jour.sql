{{ config(
    materialized = 'incremental',
    unique_key = 'RECID',
    incremental_strategy = 'merge',
    on_schema_change = 'sync_all_columns',
    liquid_clustered_by = ['SALESID']
) }}

-- One row per posted packing slip (header). Business key SALESID + PACKINGSLIPID.
SELECT
      psj.RECID
    , psj.SALESID
    , psj.PACKINGSLIPID
    , psj.SALESTYPE
    , psj.DELIVERYDATE
    , psj.DOCUMENTDATE
    , psj.ORDERACCOUNT
    , psj.INVOICEACCOUNT
    , psj.INVENTLOCATIONID
    , psj.DLVMODE
    , psj.DLVTERM
    , psj.SHIPCARRIERID
    , psj.BILLOFLADINGID
    , psj.DELIVERYPOSTALADDRESS
    , psj.RETURNITEMNUM
    , psj.RETURNPACKINGSLIPID
    , psj.QTY
    , psj.WEIGHT
    , psj.VOLUME
    , psj.POSTEDSTATE
    , psj.INTERCOMPANYPOSTED
    , psj.DATAAREAID
    , psj.CREATEDDATE
    , psj.SYNCSTARTDATETIME
FROM
    {{ ref('bronze_d365_cust_packing_slip_jour') }} psj

{% if is_incremental() %}
WHERE psj.SYNCSTARTDATETIME > (SELECT COALESCE(MAX(t.SYNCSTARTDATETIME), TIMESTAMP('1900-01-01')) FROM {{ this }} t) - INTERVAL 2 DAYS
{% endif %}
