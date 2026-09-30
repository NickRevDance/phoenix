{{ config(severity = 'warn') }}

-- EDW-149 acceptance criteria: every return reason code on a D365 return order resolves to a row in ref_return_reason_category.
-- A new code returns here (warn) until it is added to the seed; on the fact it lands in Other in the meantime. Blank codes are covered by the blank-code row and are not checked.
select
      s.RETURNREASONCODEID as return_reason_code
    , count(*) as return_orders
from {{ ref('silver_d365_sales_table') }} s
left join {{ ref('ref_return_reason_category') }} r
    on r.return_reason_code = s.RETURNREASONCODEID
where s.SALESTYPE = 4
  and nullif(trim(s.RETURNREASONCODEID), '') is not null
  and r.return_reason_code is null
group by s.RETURNREASONCODEID