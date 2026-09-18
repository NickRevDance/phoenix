-- Spec Section 8, test 1: exactly 11,688 rows (2005-01-01 through 2036-12-31)
-- Excludes the reserved unknown-member row (date_key = -1, EDW-94 A4 fast-follow,
-- added 2026-09-18) -- it is not a real calendar date and falls outside the spine.
select count(*) as row_count
from {{ ref('dim_date') }}
where date_key <> {{ unknown_member_key() }}
having count(*) <> 11688
