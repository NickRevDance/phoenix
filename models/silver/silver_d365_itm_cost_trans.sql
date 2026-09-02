{{ config(materialized = 'table') }}

-- TRANSTABLEID 14494/7637 are the D365 AOT table ids that resolve against
-- InventTrans.RECID (~93-95% match, confirmed against live data) -- excludes
-- a single stray row on an unidentified TRANSTABLEID.
SELECT
    *
FROM
    {{ ref('bronze_d365_itm_cost_trans') }}
WHERE
    TRANSTABLEID IN (14494, 7637)
