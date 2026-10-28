{{ config(
    materialized = 'incremental',
    unique_key = 'RECID',
    incremental_strategy = 'merge',
    on_schema_change = 'sync_all_columns',
    liquid_clustered_by = ['GENERALJOURNALENTRY', 'MAINACCOUNT']
) }}

-- The export is incremental on SYNCSTARTDATETIME (only changed rows get a new sync time)
SELECT
      gjae.RECID
    , gjae.GENERALJOURNALENTRY
    , gjae.MAINACCOUNT
    , SPLIT_PART(gjae.LEDGERACCOUNT, '-', 1) AS MAINACCOUNTID   -- main account number is the first segment of the ledger account display value
    , gjae.LEDGERACCOUNT
    , gjae.POSTINGTYPE
    , gjae.ISCREDIT
    , gjae.ISCORRECTION
    , gjae.ACCOUNTINGCURRENCYAMOUNT
    , gjae.REPORTINGCURRENCYAMOUNT
    , gjae.TRANSACTIONCURRENCYAMOUNT
    , gjae.TRANSACTIONCURRENCYCODE
    , gjae.HISTORICALEXCHANGERATEDATE
    , gjae.QUANTITY
    , gjae.TEXT
    , gjae.ORIGINALACCOUNTENTRY
    , gjae.REASONREF
    , gjae.ALLOCATIONLEVEL
    , gjae.FINTAG
    , gjae.PAYMENTREFERENCE
    , gjae.PROJID_SA
    , gjae.PROJTABLEDATAAREAID
    , gjae.CREATEDTRANSACTIONIDS
    , gjae.SYNCSTARTDATETIME
FROM
    {{ ref('bronze_d365_general_journal_account_entry') }} gjae

{% if is_incremental() %}
WHERE gjae.SYNCSTARTDATETIME > (SELECT COALESCE(MAX(t.SYNCSTARTDATETIME), TIMESTAMP('1900-01-01')) FROM {{ this }} t) - INTERVAL 2 DAYS
{% endif %}
