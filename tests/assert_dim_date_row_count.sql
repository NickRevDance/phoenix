-- Spec Section 8, test 1: exactly 11,688 rows (2005-01-01 through 2036-12-31)
select count(*) as row_count
from {{ ref('dim_date') }}
having count(*) <> 11688
