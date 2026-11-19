{{ config(materialized = 'table') }}

-- Raw keeps SCD2 history; current version only. Main accounts are shared across companies, so no company filter.
SELECT
      ma.recid
    , ma.mainaccountid
    , ma.name
    , ma.type
    , ma.postingtype
    , ma.ledgerchartofaccounts
    , ma.parentmainaccount
    , ma.accountcategoryref
    , ma.consolidationmainaccount
    , ma.currencycode
    , ma.debitcreditproposal
    , ma.monetary
    , ma.closing
    , ma.srucode
    , ma.modifieddatetime
    , ma.SinkModifiedOn
FROM
    {{ ref('bronze_d365_synapse_main_account') }} ma
WHERE ma.__END_AT IS NULL
