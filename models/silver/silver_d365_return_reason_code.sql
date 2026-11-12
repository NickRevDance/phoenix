{{ config(
    materialized = 'incremental',
    unique_key = ['DATAAREAID', 'REASONCODE'],
    incremental_strategy = 'merge',
    on_schema_change = 'sync_all_columns'
) }}

-- One row per customer return reason code. Merged rather than rebuilt so a run during an export reload
-- can't empty it. A code removed in D365 stays here.
SELECT
      rc.DATAAREAID
    , rc.REASONCODE
    , rc.REASONDESCRIPTION
    , rc.CUSTOMERRETURNREASONCODEGROUPID
    , rc.SYNCSTARTDATETIME
FROM
    {{ ref('bronze_d365_return_reason_code') }} rc
WHERE nullif(trim(rc.REASONCODE), '') IS NOT NULL
