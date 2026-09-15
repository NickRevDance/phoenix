{{ config(
    materialized = 'incremental',
    unique_key = 'RECID',
    incremental_strategy = 'merge',
    on_schema_change = 'sync_all_columns',
    liquid_clustered_by = ['MODIFIEDDATE', 'RECID']
) }}

-- RECID/MODIFIEDDATE selected first so Delta collects stats on them for liquid clustering
-- (default stats collection only covers the first 32 columns; this source is wider than that)
SELECT
    RECID
    , MODIFIEDDATE
    , * EXCEPT (RECID, MODIFIEDDATE)
FROM
    {{ source('byod', 'd365_inventory_trans') }}

{% if is_incremental() %}
WHERE MODIFIEDDATE > (SELECT COALESCE(MAX(MODIFIEDDATE), TIMESTAMP('1900-01-01')) FROM {{ this }}) - INTERVAL 2 DAYS
{% endif %}
