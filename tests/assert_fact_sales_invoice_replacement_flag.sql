{{ config(severity = 'warn') }}

-- EDW-184: is_replacement_order_flag on FACT_SALES_INVOICE agrees with the replacement orders
-- D365 holds today (the rule of is_replacement_flag on FACT_ORDERS_RETURNS). The flag is set when
-- a line lands and not re-read after, so this catches an order named as a replacement after its
-- lines were invoiced. Returns one row per Sales Order line that disagrees. Warn-level: a break is
-- a finding to look at and fill, not a build defect.

with replacement_order as (

    select distinct
          rt.RETURNREPLACEMENTID as order_id
    from {{ ref('silver_d365_sales_table') }} rt
    where rt.SALESTYPE = 4
      and rt.RETURNREPLACEMENTCREATED = 1
      and nullif(rt.RETURNREPLACEMENTID, '') is not null

)

select
      f.sales_invoice_key
    , f.order_id
    , f.invoice_date
    , f.is_replacement_order_flag
    , ro.order_id is not null as is_replacement_order_today
from {{ ref('fact_sales_invoice') }} f
left join replacement_order ro
    on f.order_id = ro.order_id
where f.invoice_type = 'Sales Order'
  and coalesce(f.is_replacement_order_flag, false) <> (ro.order_id is not null)