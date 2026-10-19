-- EDW-53 acceptance: all-warehouse quantities tie to the snapshot fact (native days, company-owned, MADE_TO_ORDER excluded)
-- for the code_colors the quality fact carries, over the last 7 loaded days. Returns the days that don't tie.

with quality_days as (

    select
          q.snapshot_date
        , q.code_color
        , q.total_on_hand_qty
        , q.total_available_qty

    from {{ ref('fact_inventory_quality_code_color_daily') }} q
    where q.warehouse_key is null
      and q.snapshot_date >= (select date_sub(max(x.snapshot_date), 6) from {{ ref('fact_inventory_quality_code_color_daily') }} x)

),

snapshot_side as (

    select
          f.snapshot_date
        , sum(f.on_hand_qty) as on_hand_qty
        , sum(f.available_qty) as available_qty

    from {{ ref('fact_inventory_snapshot_daily') }} f
    join {{ ref('dim_product') }} p
        on f.product_key = p.product_key
       and p.is_current_row = 1
    left join {{ ref('ref_stocking_policy') }} sp
        on f.product_id = sp.product_id
       and sp.stocking_policy = 'MADE_TO_ORDER'
    left join {{ ref('ref_inventory_status') }} st
        on f.inventory_status_code = st.inventory_status_code
       and st.is_current_row = 1
    join (select distinct qd.snapshot_date, qd.code_color from quality_days qd) qd
        on f.snapshot_date = qd.snapshot_date
       and p.code_color = qd.code_color
    where f.record_source_table = {{ inventory_snapshot_branch_label('native') }}
      and sp.product_id is null
      and coalesce(st.ownership_type, '') <> 'PARTNER_OWNED'
    group by f.snapshot_date

),

quality_side as (

    select
          qd.snapshot_date
        , sum(qd.total_on_hand_qty) as on_hand_qty
        , sum(qd.total_available_qty) as available_qty

    from quality_days qd
    group by qd.snapshot_date

)

select
      qs.snapshot_date
    , qs.on_hand_qty as quality_on_hand_qty
    , ss.on_hand_qty as snapshot_on_hand_qty
    , qs.available_qty as quality_available_qty
    , ss.available_qty as snapshot_available_qty

from quality_side qs
left join snapshot_side ss
    on qs.snapshot_date = ss.snapshot_date
where abs(coalesce(qs.on_hand_qty, 0) - coalesce(ss.on_hand_qty, 0)) > 0.001
   or abs(coalesce(qs.available_qty, 0) - coalesce(ss.available_qty, 0)) > 0.001
