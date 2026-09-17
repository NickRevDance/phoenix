-- EDW-47 acceptance criteria: exactly one active rule per rule context + size.
select
      priority, product_group, product_subgroup, gender, adult_child, style, brand, genre, age_look, size
    , count(*) as active_row_count
from {{ ref('ref_size_weight_rules') }}
where is_active = 1
group by priority, product_group, product_subgroup, gender, adult_child, style, brand, genre, age_look, size
having count(*) > 1
