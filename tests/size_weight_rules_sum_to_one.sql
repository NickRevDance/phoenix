-- EDW-47 acceptance criteria: size_weight sums to 1 per rule set (tolerance for rounding).
select
      product_group
    , product_subgroup
    , gender
    , adult_child
    , style
    , brand
    , genre
    , age_look
    , sum(size_weight) as weight_sum
from {{ ref('ref_size_weight_rules') }}
where is_active = 1
group by product_group, product_subgroup, gender, adult_child, style, brand, genre, age_look
having abs(sum(size_weight) - 1) > 0.001
