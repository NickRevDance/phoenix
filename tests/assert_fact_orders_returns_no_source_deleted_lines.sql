-- EDW-177 done-when: FACT_ORDERS_RETURNS, the current-state fact, holds no line deleted in D365.

select r.orders_returns_key, r.order_id, r.d365_sales_line_rec_id, r.open_qty
from {{ ref('fact_orders_returns') }} r
inner join {{ ref('silver_d365_sales_line') }} s
    on r.orders_returns_key = xxhash64(s.REC, 'D365')
where s.is_deleted = 1
