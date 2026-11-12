{{ config(severity = 'warn') }}

-- EDW-55: every return reason code on a D365 return order has a description in the D365 reason code export.
-- A new code returns here until the export picks it up; on the fact its description reads NULL meanwhile.
select
      s.RETURNREASONCODEID as return_reason_code
    , count(*) as return_orders
from {{ ref('silver_d365_sales_table') }} s
left join {{ ref('silver_d365_return_reason_code') }} r
    on r.REASONCODE = s.RETURNREASONCODEID
where s.SALESTYPE = 4
  and coalesce(s.is_deleted, 0) = 0
  and nullif(trim(s.RETURNREASONCODEID), '') is not null
  and r.REASONCODE is null
group by s.RETURNREASONCODEID
