{{ config(materialized = 'view') }}

-- EDW-52: prototype inventory quality scoring view (code_color grain, latest snapshot only). Scope, formula, and validation are documented in README.md.

with thresholds as (

    select
          max(case when setting_name = 'available_qty_threshold' then setting_value end) as available_qty_threshold
        , max(case when setting_name = 'healthy_threshold' then setting_value end) as healthy_threshold
        , max(case when setting_name = 'at_risk_threshold' then setting_value end) as at_risk_threshold
        , max(case when setting_name = 'broken_size_run_threshold' then setting_value end) as broken_size_run_threshold
        , max(case when setting_name = 'core_size_cumulative_pct' then setting_value end) as core_size_cumulative_pct

    from {{ ref('ref_inventory_quality_thresholds') }}
    where is_active = 1
      and scope_product_subgroup = 'ALL'

),

rules as (

    select
          rule_id
        , priority
        , product_group
        , product_subgroup
        , gender
        , adult_child
        , style
        , size
        , size_weight
        , size_rank

    from {{ ref('ref_size_weight_rules') }}
    where is_active = 1

),

latest_snapshot as (

    select max(snapshot_date) as snapshot_date
    from {{ ref('fact_inventory_snapshot_daily') }}

),

product_scope as (

    -- in-scope subgroups only -- see header comment
    select
          product_key
        , style_number
        , code_color
        , product_group
        , product_sub_group as product_subgroup
        , gender
        , adult_child
        , brand
        , size

    from {{ ref('dim_product') }}
    where is_current_row = 1
      and (product_group, product_sub_group) in (
          ('Costume', 'Costume'),
          ('Dancewear', 'Bodywear'),
          ('Dancewear', 'Shoes'),
          ('Dancewear', 'Tights')
      )

),

inv_status_current as (

    select inventory_status_code, is_sellable_flag
    from {{ ref('ref_inventory_status') }}
    where is_current_row = 1

),

fact_scope as (

    select
          f.product_key
        , f.available_qty
        , st.is_sellable_flag

    from {{ ref('fact_inventory_snapshot_daily') }} f
    cross join latest_snapshot ls
    left join inv_status_current st
        on f.inventory_status_code = st.inventory_status_code
    where f.snapshot_date = ls.snapshot_date

),

-- size-level sellable available qty: drives both the carried-size universe and the in-stock flag
size_level as (

    select
          p.product_key
        , p.style_number
        , p.code_color
        , p.product_group
        , p.product_subgroup
        , p.gender
        , p.adult_child
        , p.brand
        , p.size
        , coalesce(sum(case when f.is_sellable_flag = true then f.available_qty else 0 end), 0) as sellable_available_qty

    from product_scope p
    left join fact_scope f
        on p.product_key = f.product_key
    group by 1,2,3,4,5,6,7,8,9

),

-- priority-ladder rule match: lowest priority number wins per style+size, 'ALL' is a wildcard
rule_candidates as (

    select
          sl.style_number
        , sl.size
        , r.rule_id
        , r.priority
        , r.size_weight
        , r.size_rank
        , row_number() over (
            partition by sl.style_number, sl.size
            order by r.priority asc
          ) as match_rank

    from (select distinct style_number, size, product_group, product_subgroup, gender, adult_child from size_level) sl
    join rules r
        on (r.product_group = 'ALL' or r.product_group = sl.product_group)
       and (r.product_subgroup = 'ALL' or r.product_subgroup = sl.product_subgroup)
       and (r.gender = 'ALL' or r.gender = sl.gender)
       and (r.adult_child = 'ALL' or r.adult_child = sl.adult_child)
       and (r.style = 'ALL' or r.style = sl.style_number)
       and r.size = sl.size

),

style_size_rule as (

    select style_number, size, rule_id, size_weight, size_rank
    from rule_candidates
    where match_rank = 1

),

-- STYLE-level carried-size universe, renormalized cumulative weight, core-size flag
style_size_universe as (

    select distinct style_number, size
    from size_level

),

style_weighted as (

    select
          u.style_number
        , u.size
        , r.size_weight
        , r.size_rank

    from style_size_universe u
    left join style_size_rule r
        on u.style_number = r.style_number
       and u.size = r.size

),

style_renorm as (

    select
          style_number
        , size
        , size_weight
        , size_rank
        , size_weight / nullif(sum(size_weight) over (partition by style_number), 0) as renorm_weight

    from style_weighted
    where size_weight is not null   -- sizes with no matching rule can't be ranked; excluded from core-size math (surfaced via sizes_unmatched_to_rule below)

),

style_core as (

    select
          style_number
        , size
        , sum(renorm_weight) over (
            partition by style_number order by size_rank asc
            rows between unbounded preceding and 1 preceding
          ) as cume_weight_before

    from style_renorm

),

style_core_flagged as (

    select
          sc.style_number
        , sc.size
        , case when coalesce(sc.cume_weight_before, 0) < th.core_size_cumulative_pct then 1 else 0 end as is_core_size

    from style_core sc
    cross join thresholds th

),

-- CODE_COLOR-level weighted-availability score, using raw (unrenormalized) weight -- ratio-invariant, no renormalization needed here
code_color_size as (

    select
          sl.code_color
        , sl.style_number
        , sl.product_group
        , sl.product_subgroup
        , sl.gender
        , sl.adult_child
        , sl.brand
        , sl.size
        , sl.sellable_available_qty
        , case when sl.sellable_available_qty > th.available_qty_threshold then 1 else 0 end as in_stock_flag
        , ssr.size_weight
        , coalesce(scf.is_core_size, 0) as is_core_size

    from size_level sl
    cross join thresholds th
    left join style_size_rule ssr
        on sl.style_number = ssr.style_number and sl.size = ssr.size
    left join style_core_flagged scf
        on sl.style_number = scf.style_number and sl.size = scf.size

),

code_color_agg as (

    select
          code_color
        , any_value(style_number) as style_number
        , any_value(product_group) as product_group
        , any_value(product_subgroup) as product_subgroup
        , any_value(gender) as gender
        , any_value(adult_child) as adult_child
        , any_value(brand) as brand
        , count(*) as sizes_carried_total
        , sum(case when size_weight is null then 1 else 0 end) as sizes_unmatched_to_rule
        , sum(is_core_size) as core_sizes_total
        , sum(case when is_core_size = 1 and in_stock_flag = 1 then 1 else 0 end) as core_sizes_in_stock
        , sum(case when in_stock_flag = 1 then 1 else 0 end) as sizes_in_stock_total
        , sum(coalesce(size_weight, 0) * in_stock_flag) as weighted_in_stock
        , sum(coalesce(size_weight, 0)) as weighted_total

    from code_color_size
    group by code_color

),

scored as (

    select
          a.*
        , case when a.weighted_total > 0 then round(a.weighted_in_stock / a.weighted_total, 4) else null end as inventory_quality_score

    from code_color_agg a

),

final as (

    select
          {{ generate_surrogate_key(['s.code_color']) }} as inventory_quality_key

        , s.code_color
        , s.style_number
        , s.product_group
        , s.product_subgroup
        , s.gender
        , s.adult_child
        , s.brand
        , (select snapshot_date from latest_snapshot) as snapshot_date

        , s.sizes_carried_total
        , s.sizes_unmatched_to_rule
        , s.core_sizes_total
        , s.core_sizes_in_stock
        , s.sizes_in_stock_total
        , s.inventory_quality_score

        , case
            when s.core_sizes_total = 0 then 0
            when s.core_sizes_in_stock * 1.0 / s.core_sizes_total < th.broken_size_run_threshold then 1
            else 0
          end as broken_size_run_flag

        , case
            when s.inventory_quality_score is null then 'UNSCORED'
            when s.inventory_quality_score >= th.healthy_threshold then 'Healthy'
            when s.inventory_quality_score >= th.at_risk_threshold then 'At Risk'
            else 'Broken'
          end as quality_band

        , 'v_inventory_quality_prototype (EDW-52)' as record_source
        , current_timestamp() as etl_insert_datetime

    from scored s
    cross join thresholds th

)

select * from final
