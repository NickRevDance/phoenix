{{ config(
    materialized = 'incremental',
    unique_key = 'RECID',
    incremental_strategy = 'merge',
    on_schema_change = 'sync_all_columns',
    liquid_clustered_by = ['INVENTTRANSID']
) }}

-- One row per posted packing slip line. Joins to SalesLine on INVENTTRANSID (never on line number)
-- and to silver_d365_cust_packing_slip_jour on SALESID + PACKINGSLIPID. QTY is negative on return lines.
SELECT
      pst.RECID
    , pst.SALESID
    , pst.ORIGSALESID
    , pst.PACKINGSLIPID
    , pst.INVENTTRANSID
    , pst.LINENUM
    , pst.ITEMID
    , pst.INVENTDIMID
    , pst.QTY
    , pst.INVENTQTY
    , pst.ORDERED
    , pst.REMAIN
    , pst.REMAININVENT
    , pst.SALESUNIT
    , pst.DELIVERYDATE
    , pst.SALESLINESHIPPINGDATEREQUESTED
    , pst.SALESLINESHIPPINGDATECONFIRMED
    , pst.AMOUNTCUR
    , pst.CURRENCYCODE
    , pst.VALUEMST
    , pst.DELIVERYPOSTALADDRESS
    , pst.DELIVERYTYPE
    , pst.INVENTREFTYPE
    , pst.INVENTREFID
    , pst.INVENTREFTRANSID
    , pst.SCRAP
    , pst.DATAAREAID
    , pst.CREATEDDATE
    , pst.SYNCSTARTDATETIME
FROM
    {{ ref('bronze_d365_cust_packing_slip_trans') }} pst

{% if is_incremental() %}
WHERE pst.SYNCSTARTDATETIME > (SELECT COALESCE(MAX(t.SYNCSTARTDATETIME), TIMESTAMP('1900-01-01')) FROM {{ this }} t) - INTERVAL 2 DAYS
{% endif %}
