{{ config(materialized = 'table') }}

SELECT
    snap_p.*
FROM
    {{ref("silver_snapshot_dim_product")}} snap_p