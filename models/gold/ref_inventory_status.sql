{{ config(materialized = 'table') }}

SELECT
    snap_s.* EXCEPT (status_change_hash, notes)
    , row_number() over (
        partition by inventory_status_key
        order by version_start_date desc
    ) as version_number
    , case when version_number = 1 then 1 else 0 end as is_current_row
FROM
    {{ ref("silver_snapshot_ref_inventory_status") }} snap_s
