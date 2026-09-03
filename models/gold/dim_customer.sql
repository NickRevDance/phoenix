{{ config(materialized = 'table', schema = 'marketing_gold') }}
 
SELECT
    snap_c.*
    , cast(null as string) as scd_change_reason  -- Source once available: no per-attribute diff computed yet -- not built here, matches DIM_VENDOR precedent
    , row_number() over (
        partition by customer_key
        order by effective_start_datetime desc
    ) as version_number
    , case when version_number = 1 then 1 else 0 end as is_current_row
FROM
    {{ref("silver_snapshot_dim_customer")}} snap_c
 