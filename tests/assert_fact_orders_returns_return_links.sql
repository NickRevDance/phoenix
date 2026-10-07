{{ config(severity = 'warn') }}

-- EDW-58 (FACT_ORDERS_RETURNS spec 7.2 and 7.10): the links a return row carries to other
-- rows of the same fact. Returns one row per return line that breaks a rule. Warn-level:
-- these depend on what D365 holds, so a break is a finding to look at, not a build defect.
--   1. original_d365_sales_line_rec_id resolves to a Sales Order row.
--   2. That original row has the same product_key. Compared only when both keys are
--      resolved: a return line whose own product is Unknown ('-1') is an EDW-134 matter.
--   3. replacement_order_id resolves to a Sales Order order_id.
--   4. The replacement order carries the same rma_id as the return.

with fact as (

    select
          orders_returns_key
        , order_id
        , d365_sales_line_rec_id
        , order_type
        , product_key
        , rma_id
        , original_d365_sales_line_rec_id
        , replacement_order_id
    from {{ ref('fact_orders_returns') }}

),

linked_return as (

    select * from fact
    where order_type = 'Return Order'
      and original_d365_sales_line_rec_id is not null

),

exchange_return as (

    select * from fact
    where order_type = 'Return Order'
      and replacement_order_id is not null

),

-- One row per replacement order: a replacement order's sales rows all carry the same rma_id.
sales_order as (

    select
          order_id
        , min(rma_id) as rma_id
    from fact
    where order_type = 'Sales Order'
    group by order_id

)

select
      r.orders_returns_key
    , r.order_id
    , 'original line is not a Sales Order row' as failure
from linked_return r
left join fact o
    on r.original_d365_sales_line_rec_id = o.d365_sales_line_rec_id
where o.d365_sales_line_rec_id is null
   or o.order_type <> 'Sales Order'

union all

select
      r.orders_returns_key
    , r.order_id
    , 'original line has a different product_key' as failure
from linked_return r
inner join fact o
    on r.original_d365_sales_line_rec_id = o.d365_sales_line_rec_id
where r.product_key <> '-1'
  and o.product_key <> '-1'
  and r.product_key <> o.product_key

union all

select
      r.orders_returns_key
    , r.order_id
    , 'replacement_order_id is not a Sales Order' as failure
from exchange_return r
left join sales_order s
    on r.replacement_order_id = s.order_id
where s.order_id is null

union all

select
      r.orders_returns_key
    , r.order_id
    , 'replacement order has a different rma_id' as failure
from exchange_return r
inner join sales_order s
    on r.replacement_order_id = s.order_id
where not (r.rma_id <=> s.rma_id)