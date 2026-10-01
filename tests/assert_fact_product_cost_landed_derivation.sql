-- EDW-94 (Decision Record A8): on every LANDED row, landed_cost_unit equals
-- goods_cost_unit plus the actual components, with NULL components as zero.

select

      f.product_cost_key
    , f.product_id
    , f.landed_cost_unit
    , f.goods_cost_unit
      + coalesce(f.freight_cost_unit, 0)
      + coalesce(f.duty_cost_unit, 0)
      + coalesce(f.tariff_cost_unit, 0)
      + coalesce(f.brokerage_cost_unit, 0)
      + coalesce(f.other_landed_cost_unit, 0) as expected_landed_cost_unit

from {{ ref('fact_product_cost') }} f
where f.cost_type = 'LANDED'
    and f.is_current
    and not (
        f.landed_cost_unit <=> (
            f.goods_cost_unit
          + coalesce(f.freight_cost_unit, 0)
          + coalesce(f.duty_cost_unit, 0)
          + coalesce(f.tariff_cost_unit, 0)
          + coalesce(f.brokerage_cost_unit, 0)
          + coalesce(f.other_landed_cost_unit, 0)
        )
    )
