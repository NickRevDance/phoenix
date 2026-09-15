{{ config(materialized = 'table', schema = 'marketing_gold') }}

with segment_map as (

    select
          p.customer_key
        , s.customer_segment_key
    from {{ ref('silver_stage_customer_segment_profile') }} p
    inner join {{ ref('dim_customer_segment') }} s
        on p.customer_segment_id = s.customer_segment_id
       and s.is_current_row = 1

)

select
    snap_c.* EXCEPT (customer_segment_key)
    , sm.customer_segment_key  -- Type 1 overwrite -- always current, per DIM_CUSTOMER_SEGMENT spec section 3.1. Was a null placeholder before DIM_CUSTOMER_SEGMENT existed.
    , cast(null as string) as scd_change_reason  -- Source once available: no per-attribute diff computed yet -- not built here, matches DIM_VENDOR precedent
    , row_number() over (
        partition by snap_c.customer_key
        order by snap_c.effective_start_datetime desc
    ) as version_number
    , case when version_number = 1 then 1 else 0 end as is_current_row
from {{ref("silver_snapshot_dim_customer")}} snap_c
left join segment_map sm
    on snap_c.customer_key = sm.customer_key
