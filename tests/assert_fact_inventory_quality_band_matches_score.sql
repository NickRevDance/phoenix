-- Latest day: quality_band and inventory_quality_status agree with the score under the active ALL-scope D7 thresholds.

with thresholds as (

    select
          max(case when t.setting_name = 'healthy_threshold' then t.setting_value end) as healthy_threshold
        , max(case when t.setting_name = 'at_risk_threshold' then t.setting_value end) as at_risk_threshold

    from {{ ref('ref_inventory_quality_thresholds') }} t
    where t.is_active = 1
      and t.scope_product_subgroup = 'ALL'

),

latest as (

    select
          q.inventory_quality_key
        , q.inventory_quality_score
        , q.inventory_quality_status
        , q.quality_band

    from {{ ref('fact_inventory_quality_code_color_daily') }} q
    where q.snapshot_date = (select max(x.snapshot_date) from {{ ref('fact_inventory_quality_code_color_daily') }} x)

)

select
      l.inventory_quality_key
    , l.inventory_quality_score
    , l.inventory_quality_status
    , l.quality_band

from latest l
cross join thresholds th
where l.quality_band <> case
        when l.inventory_quality_score is null then 'UNSCORED'
        when l.inventory_quality_score >= th.healthy_threshold then 'Healthy'
        when l.inventory_quality_score >= th.at_risk_threshold then 'At Risk'
        else 'Broken'
      end
   or coalesce(l.inventory_quality_status, 'UNSCORED') <> l.quality_band
