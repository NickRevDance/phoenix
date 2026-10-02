-- EDW-151 (DIM_PRODUCT spec 3.4): the two reserved members exist exactly once each, are current,
-- and reach the current view. Returns a row for each check that fails.

with expected as (

    select '{{ unknown_member_key() }}' as product_key, 'UNKNOWN' as product_id
    union all
    select '{{ default_member_key() }}' as product_key, 'NO_PRODUCT' as product_id

)

select
      e.product_key
    , 'reserved member missing, duplicated, mislabelled or not current in dim_product' as failure
from expected e
left join {{ ref('dim_product') }} d
    on d.product_key = e.product_key
group by e.product_key
having count(d.product_key) <> 1
    or max(case when d.product_id = e.product_id and d.is_current_row = 1 and d.version_number = 1 then 1 else 0 end) <> 1

union all

select
      e.product_key
    , 'reserved member missing from v_dim_product_current' as failure
from expected e
left join {{ ref('v_dim_product_current') }} v
    on v.product_key = e.product_key
group by e.product_key
having count(v.product_key) <> 1
