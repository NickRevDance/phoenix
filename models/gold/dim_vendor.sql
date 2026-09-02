{{ config(materialized = 'table') }}

SELECT
    snap_v.*
    , row_number() over (
        partition by vendor_key
        order by effective_start_datetime desc
    ) as version_number
    , case when version_number = 1 then 1 else 0 end as is_current_row
FROM
    {{ref("silver_snapshot_dim_vendor")}} snap_v
