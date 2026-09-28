select
    count(*) as row_count
from {{ ref('dim_warehouse') }}
having count(*) = 0
