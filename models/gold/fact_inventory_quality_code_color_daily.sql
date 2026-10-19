{{ config(
    materialized = 'incremental',
    unique_key = 'inventory_quality_key',
    incremental_strategy = 'merge',
    merge_exclude_columns = ['etl_insert_datetime'],
    on_schema_change = 'sync_all_columns'
) }}

-- Incremental runs reprocess from the first of the latest loaded month so the month-end flag can move forward.
-- A rule or threshold version dated in the past, or a correction to snapshot history, needs a --full-refresh.
-- Native snapshot days only: the legacy backfill branch carries no available_qty, so D4 can't be applied to it.

with snapshot_dates_all as (

    select distinct
          f.snapshot_date
        , f.snapshot_date_key

    from {{ ref('fact_inventory_snapshot_daily') }} f
    where f.record_source_table = {{ inventory_snapshot_branch_label('native') }}

),

snapshot_window as (

    select
          d.snapshot_date
        , d.snapshot_date_key

    from snapshot_dates_all d
    {% if is_incremental() %}
    where d.snapshot_date >= (select cast(date_trunc('month', max(t.snapshot_date)) as date) from {{ this }} t)
    {% endif %}

),

snapshot_months as (

    select
          cast(date_trunc('month', d.snapshot_date) as date) as month_start_date
        , last_day(d.snapshot_date) as month_end_date
        , max(d.snapshot_date) as latest_snapshot_in_month

    from snapshot_dates_all d
    group by 1, 2

),

month_start_positions as (

    select distinct
          max(d.snapshot_date) as month_start_snapshot_date

    from snapshot_months m
    join snapshot_dates_all d
        on d.snapshot_date <= m.month_start_date
    group by m.month_start_date

),

month_end_positions as (

    select distinct
          case
            when m.month_start_date = (select max(x.month_start_date) from snapshot_months x) then m.latest_snapshot_in_month
            else m.month_end_date
          end as month_end_snapshot_date

    from snapshot_months m

),

snapshot_calendar as (

    select
          w.snapshot_date
        , w.snapshot_date_key
        , month(w.snapshot_date) as snapshot_month
        , case when ms.month_start_snapshot_date is not null then 1 else 0 end as is_month_start_snapshot
        , case when me.month_end_snapshot_date is not null then 1 else 0 end as is_month_end_snapshot

    from snapshot_window w
    left join month_start_positions ms
        on w.snapshot_date = ms.month_start_snapshot_date
    left join month_end_positions me
        on w.snapshot_date = me.month_end_snapshot_date

),

-- the first version of each setting applies back to the start of history; later versions apply from their start date
threshold_versions as (

    select
          t.setting_name
        , t.scope_product_subgroup
        , t.setting_value
        , t.effective_end_date
        , case
            when t.effective_start_date = min(t.effective_start_date) over (partition by t.setting_name, t.scope_product_subgroup) then date '1900-01-01'
            else t.effective_start_date
          end as valid_from
        , coalesce(
            lead(t.effective_start_date) over (partition by t.setting_name, t.scope_product_subgroup order by t.effective_start_date)
          , date '9999-12-31'
          ) as valid_to

    from {{ ref('ref_inventory_quality_thresholds') }} t

),

thresholds_by_scope as (

    select
          w.snapshot_date
        , tv.scope_product_subgroup
        , max(case when tv.setting_name = 'available_qty_threshold' then tv.setting_value end) as available_qty_threshold
        , max(case when tv.setting_name = 'core_size_cumulative_pct' then tv.setting_value end) as core_size_cumulative_pct
        , max(case when tv.setting_name = 'broken_size_run_threshold' then tv.setting_value end) as broken_size_run_threshold
        , max(case when tv.setting_name = 'healthy_threshold' then tv.setting_value end) as healthy_threshold
        , max(case when tv.setting_name = 'at_risk_threshold' then tv.setting_value end) as at_risk_threshold
        , max(case when tv.setting_name = 'peak_season_start_month' then tv.setting_value end) as peak_season_start_month
        , max(case when tv.setting_name = 'peak_season_end_month' then tv.setting_value end) as peak_season_end_month
        , max(case when tv.setting_name = 'pre_season_months' then tv.setting_value end) as pre_season_months

    from snapshot_window w
    join threshold_versions tv
        on w.snapshot_date >= tv.valid_from
       and w.snapshot_date < tv.valid_to
       and w.snapshot_date <= tv.effective_end_date
    group by w.snapshot_date, tv.scope_product_subgroup

),

stocking_policy as (

    select
          sp.product_id

    from {{ ref('ref_stocking_policy') }} sp
    where sp.stocking_policy = 'MADE_TO_ORDER'

),

products as (

    select
          p.product_key
        , p.product_id
        , p.code_color
        , p.size
        , p.style_number
        , p.product_group
        , p.product_sub_group as product_subgroup
        , p.gender
        , p.adult_child
        , p.brand
        , p.genre
        , p.age_look
        , case when p.erp_status in ('Active', 'Sell_to_0') then 1 else 0 end as is_scored_population

    from {{ ref('dim_product') }} p
    left join stocking_policy sp
        on p.product_id = sp.product_id
    where p.is_current_row = 1
      and p.code_color is not null
      and sp.product_id is null

),

code_color_attributes as (

    select
          p.code_color
        , max(p.style_number) as style_number
        , max(p.product_group) as product_group
        , max(p.product_subgroup) as product_subgroup
        , max(p.gender) as gender
        , max(p.adult_child) as adult_child
        , max(p.brand) as brand
        , max(p.genre) as genre
        , max(p.age_look) as age_look

    from products p
    where p.is_scored_population = 1
    group by p.code_color

),

code_color_sizes as (

    select distinct
          p.code_color
        , p.size

    from products p
    where p.is_scored_population = 1

),

-- a code_color is scored from the first day it appears in the snapshot, so styles launched later don't read as stocked out in earlier history
code_color_first_seen as (

    select
          p.code_color
        , min(f.snapshot_date) as first_snapshot_date

    from {{ ref('fact_inventory_snapshot_daily') }} f
    join products p
        on f.product_key = p.product_key
    where f.record_source_table = {{ inventory_snapshot_branch_label('native') }}
    group by p.code_color

),

code_color_dates as (

    select
          c.snapshot_date
        , c.snapshot_date_key
        , c.snapshot_month
        , c.is_month_start_snapshot
        , c.is_month_end_snapshot
        , a.code_color
        , a.style_number
        , a.product_group
        , a.product_subgroup
        , a.gender
        , a.adult_child
        , a.brand
        , a.genre
        , a.age_look

    from snapshot_calendar c
    join code_color_first_seen fs
        on fs.first_snapshot_date <= c.snapshot_date
    join code_color_attributes a
        on fs.code_color = a.code_color

),

code_color_settings as (

    select
          c.snapshot_date
        , c.code_color
        , coalesce(sg.available_qty_threshold, al.available_qty_threshold) as available_qty_threshold
        , coalesce(sg.core_size_cumulative_pct, al.core_size_cumulative_pct) as core_size_cumulative_pct
        , coalesce(sg.broken_size_run_threshold, al.broken_size_run_threshold) as broken_size_run_threshold
        , coalesce(sg.healthy_threshold, al.healthy_threshold) as healthy_threshold
        , coalesce(sg.at_risk_threshold, al.at_risk_threshold) as at_risk_threshold
        , cast(coalesce(sg.peak_season_start_month, al.peak_season_start_month) as int) as peak_season_start_month
        , cast(coalesce(sg.peak_season_end_month, al.peak_season_end_month) as int) as peak_season_end_month
        , cast(coalesce(sg.pre_season_months, al.pre_season_months) as int) as pre_season_months

    from code_color_dates c
    left join thresholds_by_scope sg
        on c.snapshot_date = sg.snapshot_date
       and c.product_subgroup = sg.scope_product_subgroup
    left join thresholds_by_scope al
        on c.snapshot_date = al.snapshot_date
       and al.scope_product_subgroup = 'ALL'

),

rules as (

    select
          r.rule_id
        , concat_ws('|'
            , cast(r.priority as string), r.product_group, r.product_subgroup, r.gender, r.adult_child, r.style
            , coalesce(r.brand, 'ALL'), coalesce(r.genre, 'ALL'), coalesce(r.age_look, 'ALL')
          ) as rule_set_id
        , r.priority
        , r.product_group
        , r.product_subgroup
        , r.gender
        , r.adult_child
        , r.style
        , coalesce(r.brand, 'ALL') as brand
        , coalesce(r.genre, 'ALL') as genre
        , coalesce(r.age_look, 'ALL') as age_look
        , r.size
        , r.size_weight
        , r.size_rank
        , r.is_core_size
        , r.effective_start_date
        , r.effective_end_date

    from {{ ref('ref_size_weight_rules') }} r

),

rule_set_versions as (

    select
          r.rule_set_id
        , r.effective_start_date
        , max(r.effective_end_date) as effective_end_date
        , max(r.priority) as priority
        , max(r.product_group) as product_group
        , max(r.product_subgroup) as product_subgroup
        , max(r.gender) as gender
        , max(r.adult_child) as adult_child
        , max(r.style) as style
        , max(r.brand) as brand
        , max(r.genre) as genre
        , max(r.age_look) as age_look

    from rules r
    group by r.rule_set_id, r.effective_start_date

),

-- the first version of each rule set applies back to the start of history; later versions apply from their start date
rule_set_validity as (

    select
          v.rule_set_id
        , v.effective_start_date
        , v.effective_end_date
        , v.priority
        , v.product_group
        , v.product_subgroup
        , v.gender
        , v.adult_child
        , v.style
        , v.brand
        , v.genre
        , v.age_look
        , case
            when v.effective_start_date = min(v.effective_start_date) over (partition by v.rule_set_id) then date '1900-01-01'
            else v.effective_start_date
          end as valid_from
        , coalesce(
            lead(v.effective_start_date) over (partition by v.rule_set_id order by v.effective_start_date)
          , date '9999-12-31'
          ) as valid_to

    from rule_set_versions v

),

-- priority matching: the lowest priority value among the rule sets that match the code_color wins; 'ALL' is a wildcard
rule_set_candidates as (

    select
          c.snapshot_date
        , c.code_color
        , rs.rule_set_id
        , rs.effective_start_date
        , row_number() over (
            partition by c.snapshot_date, c.code_color
            order by rs.priority asc, rs.rule_set_id asc
          ) as match_rank

    from code_color_dates c
    join rule_set_validity rs
        on c.snapshot_date >= rs.valid_from
       and c.snapshot_date < rs.valid_to
       and c.snapshot_date <= rs.effective_end_date
       and rs.product_group in ('ALL', c.product_group)
       and rs.product_subgroup in ('ALL', c.product_subgroup)
       and rs.gender in ('ALL', c.gender)
       and rs.adult_child in ('ALL', c.adult_child)
       and rs.style in ('ALL', c.style_number)
       and rs.brand in ('ALL', c.brand)
       and rs.genre in ('ALL', c.genre)
       and rs.age_look in ('ALL', c.age_look)

),

matched_rule_set as (

    select
          rc.snapshot_date
        , rc.code_color
        , rc.rule_set_id
        , rc.effective_start_date

    from rule_set_candidates rc
    where rc.match_rank = 1

),

code_color_size_weights as (

    select
          c.snapshot_date
        , c.code_color
        , s.size
        , r.size_weight
        , r.size_rank
        , r.is_core_size as is_core_size_override

    from code_color_dates c
    join code_color_sizes s
        on c.code_color = s.code_color
    left join matched_rule_set m
        on c.snapshot_date = m.snapshot_date
       and c.code_color = m.code_color
    left join rules r
        on m.rule_set_id = r.rule_set_id
       and m.effective_start_date = r.effective_start_date
       and s.size = r.size

),

-- D1: core sizes per code_color over the sizes it is made in, weights rescaled to sum to 1, ranked by weight descending
code_color_core_cumulative as (

    select
          w.snapshot_date
        , w.code_color
        , w.size
        , w.is_core_size_override
        , sum(w.size_weight) over (
            partition by w.snapshot_date, w.code_color
            order by w.size_weight desc, w.size_rank asc, w.size asc
            rows between unbounded preceding and 1 preceding
          ) / nullif(sum(w.size_weight) over (partition by w.snapshot_date, w.code_color), 0) as cumulative_weight_before

    from code_color_size_weights w
    where w.size_weight is not null

),

code_color_sizes_flagged as (

    select
          w.snapshot_date
        , w.code_color
        , w.size
        , w.size_weight
        , case
            when w.size_weight is null then cast(null as int)
            when cc.is_core_size_override is not null then cast(cc.is_core_size_override as int)
            when coalesce(cc.cumulative_weight_before, 0) < st.core_size_cumulative_pct then 1
            else 0
          end as is_core_size

    from code_color_size_weights w
    left join code_color_core_cumulative cc
        on w.snapshot_date = cc.snapshot_date
       and w.code_color = cc.code_color
       and w.size = cc.size
    join code_color_settings st
        on w.snapshot_date = st.snapshot_date
       and w.code_color = st.code_color

),

inventory_status as (

    select
          s.inventory_status_code
        , s.ownership_type
        , cast(s.is_sellable_flag as boolean) as is_sellable

    from {{ ref('ref_inventory_status') }} s
    where s.is_current_row = 1

),

stock_rows as (

    select
          f.snapshot_date
        , p.code_color
        , p.size
        , f.warehouse_key
        , f.on_hand_qty
        , f.available_qty
        , f.moving_avg_cost_amount
        , f.retail_value_amount
        , case
            when p.is_scored_population = 1 and coalesce(st.is_sellable, false) then f.available_qty
            else 0
          end as sellable_available_qty

    from {{ ref('fact_inventory_snapshot_daily') }} f
    join snapshot_window w
        on f.snapshot_date = w.snapshot_date
    join products p
        on f.product_key = p.product_key
    left join stocking_policy sp
        on f.product_id = sp.product_id
    left join inventory_status st
        on f.inventory_status_code = st.inventory_status_code
    where f.record_source_table = {{ inventory_snapshot_branch_label('native') }}
      and sp.product_id is null
      and coalesce(st.ownership_type, '') <> 'PARTNER_OWNED'

),

stock_by_size as (

    select
          s.snapshot_date
        , s.code_color
        , s.size
        , 0 as is_all_warehouse_row
        , s.warehouse_key
        , sum(s.on_hand_qty) as on_hand_qty
        , sum(s.available_qty) as available_qty
        , sum(s.moving_avg_cost_amount) as on_hand_cost
        , sum(s.retail_value_amount) as retail_value
        , sum(s.sellable_available_qty) as sellable_available_qty

    from stock_rows s
    group by s.snapshot_date, s.code_color, s.size, s.warehouse_key

    union all

    select
          s.snapshot_date
        , s.code_color
        , s.size
        , 1 as is_all_warehouse_row
        , cast(null as bigint) as warehouse_key
        , sum(s.on_hand_qty) as on_hand_qty
        , sum(s.available_qty) as available_qty
        , sum(s.moving_avg_cost_amount) as on_hand_cost
        , sum(s.retail_value_amount) as retail_value
        , sum(s.sellable_available_qty) as sellable_available_qty

    from stock_rows s
    group by s.snapshot_date, s.code_color, s.size

),

code_color_warehouses as (

    select
          c.snapshot_date
        , c.code_color
        , 1 as is_all_warehouse_row
        , cast(null as bigint) as warehouse_key

    from code_color_dates c

    union all

    select distinct
          s.snapshot_date
        , s.code_color
        , 0 as is_all_warehouse_row
        , s.warehouse_key

    from stock_by_size s
    join code_color_dates c
        on s.snapshot_date = c.snapshot_date
       and s.code_color = c.code_color
    where s.is_all_warehouse_row = 0

),

-- D4: sellable available qty summed to size level (and across warehouses for the headline row), then compared to the threshold
size_grid as (

    select
          cw.snapshot_date
        , cw.code_color
        , cw.is_all_warehouse_row
        , cw.warehouse_key
        , sz.size
        , sz.size_weight
        , sz.is_core_size
        , case when coalesce(sb.sellable_available_qty, 0) > st.available_qty_threshold then 1 else 0 end as is_in_stock

    from code_color_warehouses cw
    join code_color_sizes_flagged sz
        on cw.snapshot_date = sz.snapshot_date
       and cw.code_color = sz.code_color
    join code_color_settings st
        on cw.snapshot_date = st.snapshot_date
       and cw.code_color = st.code_color
    left join stock_by_size sb
        on cw.snapshot_date = sb.snapshot_date
       and cw.code_color = sb.code_color
       and cw.is_all_warehouse_row = sb.is_all_warehouse_row
       and cw.warehouse_key <=> sb.warehouse_key
       and sz.size = sb.size

),

size_run as (

    select
          g.snapshot_date
        , g.code_color
        , g.is_all_warehouse_row
        , g.warehouse_key
        , sum(case when g.size_weight is not null then 1 else 0 end) as size_count_total
        , sum(case when g.size_weight is not null and g.is_in_stock = 1 then 1 else 0 end) as size_count_in_stock
        , sum(case when g.size_weight is null then 1 else 0 end) as unmatched_size_count
        , sum(case when g.is_core_size = 1 then 1 else 0 end) as core_size_count_total
        , sum(case when g.is_core_size = 1 and g.is_in_stock = 1 then 1 else 0 end) as core_size_count_in_stock
        , sum(g.size_weight) as size_weight_total
        , sum(case when g.is_in_stock = 1 then g.size_weight else 0 end) as size_weight_in_stock

    from size_grid g
    group by g.snapshot_date, g.code_color, g.is_all_warehouse_row, g.warehouse_key

),

quantities as (

    select
          s.snapshot_date
        , s.code_color
        , s.is_all_warehouse_row
        , s.warehouse_key
        , sum(s.on_hand_qty) as total_on_hand_qty
        , sum(s.available_qty) as total_available_qty
        , sum(s.on_hand_cost) as total_on_hand_cost
        , sum(s.retail_value) as total_retail_value

    from stock_by_size s
    group by s.snapshot_date, s.code_color, s.is_all_warehouse_row, s.warehouse_key

),

scored as (

    select
          cw.snapshot_date
        , cw.code_color
        , cw.is_all_warehouse_row
        , cw.warehouse_key
        , coalesce(sr.size_count_total, 0) as size_count_total
        , coalesce(sr.size_count_in_stock, 0) as size_count_in_stock
        , coalesce(sr.unmatched_size_count, 0) as unmatched_size_count
        , coalesce(sr.core_size_count_total, 0) as core_size_count_total
        , coalesce(sr.core_size_count_in_stock, 0) as core_size_count_in_stock
        , case
            when sr.core_size_count_total > 0 then cast(round(sr.core_size_count_in_stock / sr.core_size_count_total, 4) as decimal(9,4))
          end as core_size_completeness_pct
        , cast(sr.size_weight_total as decimal(9,6)) as size_weight_total
        , cast(case when sr.size_weight_total > 0 then sr.size_weight_in_stock end as decimal(9,6)) as size_weight_in_stock
        , case
            when sr.size_weight_total > 0 then cast(round(sr.size_weight_in_stock / sr.size_weight_total, 4) as decimal(9,4))
          end as inventory_quality_score
        , cast(coalesce(q.total_on_hand_qty, 0) as decimal(18,4)) as total_on_hand_qty
        , cast(coalesce(q.total_available_qty, 0) as decimal(18,4)) as total_available_qty
        , cast(q.total_on_hand_cost as decimal(19,4)) as total_on_hand_cost
        , cast(q.total_retail_value as decimal(19,4)) as total_retail_value

    from code_color_warehouses cw
    left join size_run sr
        on cw.snapshot_date = sr.snapshot_date
       and cw.code_color = sr.code_color
       and cw.is_all_warehouse_row = sr.is_all_warehouse_row
       and cw.warehouse_key <=> sr.warehouse_key
    left join quantities q
        on cw.snapshot_date = q.snapshot_date
       and cw.code_color = q.code_color
       and cw.is_all_warehouse_row = q.is_all_warehouse_row
       and cw.warehouse_key <=> q.warehouse_key

),

final as (

    select
          xxhash64(s.snapshot_date, s.code_color, coalesce(cast(s.warehouse_key as string), 'ALL')) as inventory_quality_key
        , c.snapshot_date_key
        , s.snapshot_date
        , s.code_color
        , cast(null as bigint) as product_hierarchy_key  -- Source once available: DIM_PRODUCT_HIERARCHY -- not specced; hierarchy resolves to DIM_PRODUCT attributes in v_current_inventory_quality
        , s.warehouse_key
        , 'D365' as source_system

        , c.style_number
        , c.product_group
        , c.product_subgroup

        , case
            when (st.peak_season_start_month <= st.peak_season_end_month and c.snapshot_month between st.peak_season_start_month and st.peak_season_end_month)
              or (st.peak_season_start_month > st.peak_season_end_month and (c.snapshot_month >= st.peak_season_start_month or c.snapshot_month <= st.peak_season_end_month))
                then 'Peak'
            when mod(st.peak_season_start_month - c.snapshot_month + 12, 12) between 1 and st.pre_season_months then 'Pre-season'
            else 'Off-season'
          end as season_phase
        , c.is_month_start_snapshot
        , c.is_month_end_snapshot

        , s.total_on_hand_qty
        , s.total_available_qty
        , s.total_on_hand_cost
        , s.total_retail_value

        , s.size_count_total
        , s.size_count_in_stock
        , s.unmatched_size_count
        , s.core_size_count_total
        , s.core_size_count_in_stock
        , s.core_size_completeness_pct
        , case
            when s.core_size_completeness_pct is null then cast(null as int)
            when s.core_size_completeness_pct < st.broken_size_run_threshold then 1
            else 0
          end as broken_size_run_flag

        , s.size_weight_total
        , s.size_weight_in_stock
        , s.inventory_quality_score
        , case
            when s.inventory_quality_score is null then cast(null as string)
            when s.inventory_quality_score >= st.healthy_threshold then 'Healthy'
            when s.inventory_quality_score >= st.at_risk_threshold then 'At Risk'
            else 'Broken'
          end as inventory_quality_status
        , case
            when s.inventory_quality_score is null then 'UNSCORED'
            when s.inventory_quality_score >= st.healthy_threshold then 'Healthy'
            when s.inventory_quality_score >= st.at_risk_threshold then 'At Risk'
            else 'Broken'
          end as quality_band  -- prototype name, kept for the Inventory Executive report cutover
        , cast(null as int) as avg_days_on_hand  -- Source once available: an age source for D5 -- days_on_hand_age is retired on the snapshot fact
        , cast(null as decimal(9,4)) as aged_inventory_pct  -- Source once available: an age source for D5 -- days_on_hand_age is retired on the snapshot fact

        , cast(null as decimal(9,4)) as sell_through_rate_30d  -- Source once available: certified sales fact -- Phase 3
        , cast(null as decimal(9,4)) as sell_through_rate_90d  -- Source once available: certified sales fact -- Phase 3
        , cast(null as decimal(18,4)) as units_sold_30d  -- Source once available: certified sales fact -- Phase 3

        , current_timestamp() as etl_insert_datetime
        , current_timestamp() as etl_update_datetime
        , sha2(concat_ws('||'
            , coalesce(cast(s.total_on_hand_qty as string), '')
            , coalesce(cast(s.total_available_qty as string), '')
            , coalesce(cast(s.total_on_hand_cost as string), '')
            , coalesce(cast(s.total_retail_value as string), '')
            , coalesce(cast(s.size_count_total as string), '')
            , coalesce(cast(s.size_count_in_stock as string), '')
            , coalesce(cast(s.unmatched_size_count as string), '')
            , coalesce(cast(s.core_size_count_total as string), '')
            , coalesce(cast(s.core_size_count_in_stock as string), '')
            , coalesce(cast(s.inventory_quality_score as string), '')
            , coalesce(cast(c.is_month_start_snapshot as string), '')
            , coalesce(cast(c.is_month_end_snapshot as string), '')
          ), 256) as row_hash

    from scored s
    join code_color_dates c
        on s.snapshot_date = c.snapshot_date
       and s.code_color = c.code_color
    join code_color_settings st
        on s.snapshot_date = st.snapshot_date
       and s.code_color = st.code_color

)

select * from final
