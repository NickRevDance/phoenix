{{ config(materialized = 'table') }}

-- Raw keeps SCD2 history; current version only. A row deleted in D365 has no current version, so a rebuild drops it.
SELECT
      tt.recid
    , tt.dataareaid
    , tt.transdate
    , tt.voucher
    , tt.invoiceid
    , tt.sourcetableid
    , tt.sourcerecid
    , tt.sourcedocumentline
    , tt.inventtransid
    , tt.taxcode
    , tt.taxgroup
    , tt.taxitemgroup
    , tt.taxdirection
    , tt.taxorigin
    , tt.taxperiod
    , tt.currencycode
    , tt.sourcecurrencycode
    , tt.taxbaseamount
    , tt.taxbaseamountcur
    , tt.sourcebaseamountcur
    , tt.taxbaseqty
    , tt.taxamount
    , tt.taxamountcur
    , tt.sourcetaxamountcur
    , tt.taxvalue
    , tt.taxincostprice
    , tt.exempttax
    , tt.exemptcode
    , tt.vtxtaxareaid
    , tt.vtxtaxtype
    , tt.vtxjurisdictionlevel
    , tt.vtxjurisdictionvalue
    , tt.vtximpositionvalue
    , tt.vtxvertextaxrate
    , tt.createddatetime
    , tt.modifieddatetime
    , tt.SinkModifiedOn
FROM
    {{ ref('bronze_d365_synapse_tax_trans') }} tt
WHERE tt.__END_AT IS NULL
  AND tt.dataareaid <> 'dat'
