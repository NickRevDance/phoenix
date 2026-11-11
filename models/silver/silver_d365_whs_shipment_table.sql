{{ config(materialized = 'table') }}

-- Full rebuild each run: open shipments are re-planned and deleted in D365, so a merge would keep stale rows.
-- Outbound WMS shipment header, one row per SHIPMENTID. ADDRESS and DELIVERYNAME are left out (PII); the ship-to resolves through LOCATION_LOCATIONID + LOGISTICSPOSTALADDRESS_VALIDFROM.

{% if empty_extract_guard(ref('bronze_d365_whs_shipment_table'), 1) %}

SELECT
    t.*
FROM
    {{ this }} t

{% else %}

SELECT
      sh.SHIPMENTID
    , sh.SHIPMENTSTATUS
    , sh.WORKTRANSTYPE
    , sh.LOADDIRECTION
    , sh.LOADID
    , sh.ORDERNUM
    , sh.ACCOUNTNUM
    , sh.INVENTLOCATIONID
    , sh.INVENTSITEID
    , sh.CARRIERCODE
    , sh.CARRIERSERVICECODE
    , sh.CARRIERGROUPCODE
    , sh.MODECODE
    , sh.SCAC
    , sh.PRONUM
    , sh.WAYBILL
    , sh.BILLOFLADINGID
    , sh.SHIPCARRIERACCOUNT
    , sh.DLVTERMID
    , sh.FREIGHTTERMCODE
    , sh.COUNTRYREGIONISOCODE
    , sh.LOCATION_LOCATIONID
    , sh.LOGISTICSPOSTALADDRESS_VALIDFROM
    , sh.MANIFESTEDWEIGHT
    , sh.MANIFESTEDWEIGHTUOM
    , sh.WAVEID
    , sh.SHIPMENTCREATEDUTCDATETIME
    , sh.SHIPCONFIRMUTCDATETIME
    , sh.SHIPMENTARRIVALUTCDATETIME
    , sh.DROPOFFUTCDATETIME
    , sh.CREATEDDATE
    , sh.MODIFIEDDATE
    , sh.REC
    , sh.DATAAREAID
    , sh.SYNCSTARTDATETIME
FROM
    {{ ref('bronze_d365_whs_shipment_table') }} sh

{% endif %}
