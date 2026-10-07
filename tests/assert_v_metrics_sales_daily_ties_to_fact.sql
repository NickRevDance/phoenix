-- EDW-133 (shape section, build notes): V_METRICS_SALES_DAILY represents every row of
-- FACT_SALES_INVOICE, so each additive measure summed over the view equals the same sum over
-- the fact. A difference means a filter crept into the view or a dimension join fanned out.
-- Returns a row for each measure that does not tie.

with fact_totals as (

    select
          cast(count(*) as decimal(38,6))                            as invoice_line_count
        , coalesce(sum(invoiced_qty), 0)                             as invoiced_qty
        , coalesce(sum(gross_sales_amount), 0)                       as gross_sales_amount
        , coalesce(sum(total_discount_amount), 0)                    as total_discount_amount
        , coalesce(sum(net_sales_amount), 0)                         as net_sales_amount
        , coalesce(sum(standard_cost_amount), 0)                     as standard_cost_amount
    from {{ ref('fact_sales_invoice') }}

),

view_totals as (

    select
          cast(coalesce(sum(invoice_line_count), 0) as decimal(38,6)) as invoice_line_count
        , coalesce(sum(invoiced_qty), 0)                             as invoiced_qty
        , coalesce(sum(gross_sales_amount), 0)                       as gross_sales_amount
        , coalesce(sum(total_discount_amount), 0)                    as total_discount_amount
        , coalesce(sum(net_sales_amount), 0)                         as net_sales_amount
        , coalesce(sum(standard_cost_amount), 0)                     as standard_cost_amount
    from {{ ref('v_metrics_sales_daily') }}

)

select
      'invoice_line_count' as failure
    , cast(v.invoice_line_count as decimal(38,6)) as value_found
    , cast(f.invoice_line_count as decimal(38,6)) as value_expected
from view_totals v
cross join fact_totals f
where v.invoice_line_count <> f.invoice_line_count

union all

select
      'invoiced_qty'
    , cast(v.invoiced_qty as decimal(38,6))
    , cast(f.invoiced_qty as decimal(38,6))
from view_totals v
cross join fact_totals f
where v.invoiced_qty <> f.invoiced_qty

union all

select
      'gross_sales_amount'
    , cast(v.gross_sales_amount as decimal(38,6))
    , cast(f.gross_sales_amount as decimal(38,6))
from view_totals v
cross join fact_totals f
where v.gross_sales_amount <> f.gross_sales_amount

union all

select
      'total_discount_amount'
    , cast(v.total_discount_amount as decimal(38,6))
    , cast(f.total_discount_amount as decimal(38,6))
from view_totals v
cross join fact_totals f
where v.total_discount_amount <> f.total_discount_amount

union all

select
      'net_sales_amount'
    , cast(v.net_sales_amount as decimal(38,6))
    , cast(f.net_sales_amount as decimal(38,6))
from view_totals v
cross join fact_totals f
where v.net_sales_amount <> f.net_sales_amount

union all

select
      'standard_cost_amount'
    , cast(v.standard_cost_amount as decimal(38,6))
    , cast(f.standard_cost_amount as decimal(38,6))
from view_totals v
cross join fact_totals f
where v.standard_cost_amount <> f.standard_cost_amount