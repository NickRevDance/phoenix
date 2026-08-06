{{ config(materialized = 'view') }}

SELECT
    snap_p.*
FROM
    {{ref("silver_snapshot_dim_product")}} snap_p
WHERE
    snap_p.dbt_valid_from <= now()
    and coalesce(snap_p.dbt_valid_to, now()) >= now()