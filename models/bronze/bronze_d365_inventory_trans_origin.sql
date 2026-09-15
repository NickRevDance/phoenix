{{ config(
    materialized = 'incremental',
    unique_key = 'RECID',
    incremental_strategy = 'merge',
    on_schema_change = 'sync_all_columns',
    liquid_clustered_by = ['SYNCSTARTDATETIME', 'RECID']
) }}

-- SYNCSTARTDATETIME/RECID selected first so Delta collects stats on them for liquid clustering
-- (default stats collection only covers the first 32 columns; this source is wider than that)
SELECT
    SYNCSTARTDATETIME
    , RECID
    , * EXCEPT (SYNCSTARTDATETIME, RECID)
FROM
    {{ source('byod', 'd365_inventory_trans_origin') }}

{% if is_incremental() %}
WHERE SYNCSTARTDATETIME > (SELECT COALESCE(MAX(SYNCSTARTDATETIME), TIMESTAMP('1900-01-01')) FROM {{ this }}) - INTERVAL 2 DAYS
{% endif %}
