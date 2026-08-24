{{ config(materialized = 'table') }}

SELECT
    snap_s.* EXCEPT (status_change_hash, notes, include_in_std_metrics_flag)
    , boolean(include_in_std_metrics_flag) as include_in_std_metrics_flag
    , row_number() over (
        partition by inventory_status_key
        order by version_start_date desc
    ) as version_number
    , case when version_number = 1 then 1 else 0 end as is_current_row
FROM
    {{ ref("silver_snapshot_ref_inventory_status") }} snap_s
