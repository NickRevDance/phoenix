{{ config(
    materialized = 'incremental',
    unique_key = 'RECID',
    incremental_strategy = 'merge',
    on_schema_change = 'sync_all_columns',
    liquid_clustered_by = ['ACCOUNTINGDATE', 'RECID']
) }}

-- The export reloads every header daily, so this merges the full extract; merging (not rebuilding) keeps a half-loaded extract from dropping headers
SELECT
      gje.RECID
    , gje.LEDGER
    , UPPER(gje.SUBLEDGERVOUCHERDATAAREAID) AS DATAAREAID   -- source mixes case (rev/REV)
    , gje.SUBLEDGERVOUCHERDATAAREAID
    , gje.SUBLEDGERVOUCHER
    , gje.ACCOUNTINGDATE
    , gje.DOCUMENTDATE
    , gje.DOCUMENTNUMBER
    , gje.CREATEDDATE
    , gje.CREATEDBYUSER
    , gje.ACKNOWLEDGEMENTDATE
    , gje.FISCALCALENDARYEAR
    , gje.FISCALCALENDARPERIOD
    , gje.JOURNALCATEGORY
    , gje.JOURNALNUMBER
    , gje.POSTINGLAYER
    , gje.LEDGERENTRYJOURNAL
    , gje.LEDGERPOSTINGJOURNAL
    , gje.LEDGERPOSTINGJOURNALDATAAREAID
    , gje.TRANSFERID
    , gje.BUDGETSOURCELEDGERENTRYPOSTED
    , gje.CREATEDTRANSACTIONIDS
    , gje.SYNCSTARTDATETIME
FROM
    {{ ref('bronze_d365_general_journal_entry') }} gje

{% if is_incremental() %}
WHERE gje.SYNCSTARTDATETIME > (SELECT COALESCE(MAX(t.SYNCSTARTDATETIME), TIMESTAMP('1900-01-01')) FROM {{ this }} t) - INTERVAL 2 DAYS
{% endif %}
