{{ config(materialized = 'table') }}

-- Full rebuild each run: open shipments are re-planned and deleted in D365, so a merge would keep stale rows.
-- One row per packed container (package). MASTERTRACKINGNUM carries the carrier tracking number; SHIPCARRIERTRACKINGNUM holds free-text notes as often as numbers.

{% if empty_extract_guard(ref('bronze_d365_whs_container_table'), 1) %}

SELECT
    t.*
FROM
    {{ this }} t

{% else %}

SELECT
      ct.REC
    , ct.CONTAINERID
    , ct.SHIPMENTID
    , ct.CONTAINERSTATUS
    , ct.CONTAINERTYPECODE
    , ct.CONTAINERNUM
    , ct.PARENTCONTAINERID
    , ct.CONTAINERLEVEL
    , ct.MASTERTRACKINGNUM
    , ct.SHIPCARRIERTRACKINGNUM
    , ct.WEIGHT
    , ct.WEIGHTUOM
    , ct.HEIGHT
    , ct.LENGTH
    , ct.WIDTH
    , ct.CLOSECONTAINERUTCDATETIME
    , ct.REVCONFIRMDATETIME
    , ct.REVUSPSLABELID
    , ct.CREATEDDATE
    , ct.MODIFIEDDATE
    , ct.DATAAREAID
    , ct.SYNCSTARTDATETIME
FROM
    {{ ref('bronze_d365_whs_container_table') }} ct

{% endif %}
