-- Returns a row (fails) unless dim_customer carries exactly one current -1 Unknown member.
select
      count(*) as unknown_member_rows
from {{ ref('dim_customer') }}
where customer_key = {{ unknown_member_key() }}
  and customer_id = 'UNKNOWN'
  and customer_type = 'Unknown'
  and customer_status = 'Unknown'
  and is_current_row = 1
having count(*) <> 1
