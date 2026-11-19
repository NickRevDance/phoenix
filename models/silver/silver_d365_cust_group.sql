{{ config(materialized = 'table') }}

-- Raw keeps SCD2 history; current version only. 'dat' is the D365 system company.
SELECT
      cg.recid
    , cg.dataareaid
    , cg.custgroup
    , cg.name
    , cg.paymtermid
    , cg.taxgroupid
    , cg.clearingperiod
    , cg.defaultdimension
    , cg.modifieddatetime
    , cg.SinkModifiedOn
FROM
    {{ ref('bronze_d365_synapse_cust_group') }} cg
WHERE cg.__END_AT IS NULL
  AND cg.dataareaid <> 'dat'
