{{ config(materialized = 'table') }}

-- Raw keeps SCD2 history; current version only. 'dat' is the D365 system company.
SELECT
      dm.recid
    , dm.dataareaid
    , dm.code
    , dm.txt
    , dm.shipcarrierid
    , dm.shipcarriername
    , dm.shipcarrieraccountcode
    , dm.shipcarrierdlvtype
    , dm.transport
    , dm.mcrexpedite
    , dm.markupgroup
    , dm.modifieddatetime
    , dm.SinkModifiedOn
FROM
    {{ ref('bronze_d365_synapse_dlv_mode') }} dm
WHERE dm.__END_AT IS NULL
  AND dm.dataareaid <> 'dat'
