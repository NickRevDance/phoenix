{{ config(materialized = 'table') }}

-- Raw keeps SCD2 history; current version only. A row deleted in D365 has no current version, so a rebuild drops it.
SELECT
      mt.recid
    , mt.dataareaid
    , mt.transtableid
    , mt.transrecid
    , mt.origtableid
    , mt.origrecid
    , mt.custinvoicelineidref
    , mt.moduletype
    , mt.modulecategory
    , mt.markupcategory
    , mt.markupcode
    , mt.txt
    , mt.linenum
    , mt.transdate
    , mt.voucher
    , mt.currencycode
    , mt.value
    , mt.calculatedamount
    , mt.posted
    , mt.taxamount
    , mt.taxgroup
    , mt.taxitemgroup
    , mt.keep
    , mt.isdeleted
    , mt.isautocharge
    , mt.mcrreasoncode
    , mt.retailshippingpromotiondiscount
    , mt.revreplaceshippingcharge
    , mt.createddatetime
    , mt.modifieddatetime
    , mt.SinkModifiedOn
FROM
    {{ ref('bronze_d365_synapse_markup_trans') }} mt
WHERE mt.__END_AT IS NULL
  AND mt.dataareaid <> 'dat'
