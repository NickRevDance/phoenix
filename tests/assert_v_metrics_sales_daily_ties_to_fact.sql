-- EDW-133 (shape section, build notes): V_METRICS_SALES_DAILY represents every row of
-- FACT_SALES_INVOICE, so each additive measure summed over the view equals the same sum over
-- the fact. A difference means a filter crept into the view or a dimension join fanned out.
-- Returns a row for each measure that does not tie. EDW-169 adds the USD, Nimbly and wholesale measures;
-- EDW-182 adds the posted cost.

with fact_totals as (

    select
          cast(count(*) as decimal(38,6))                            as invoice_line_count
        , coalesce(sum(invoiced_qty), 0)                             as invoiced_qty
        , coalesce(sum(gross_sales_amount), 0)                       as gross_sales_amount
        , coalesce(sum(total_discount_amount), 0)                    as total_discount_amount
        , coalesce(sum(net_sales_amount), 0)                         as net_sales_amount
        , coalesce(sum(standard_cost_amount), 0)                     as standard_cost_amount
        , coalesce(sum(moving_avg_cost_amount), 0)                   as moving_avg_cost_amount
        , coalesce(sum(net_sales_amount_usd), 0)        as net_sales_amount_usd
        , coalesce(sum(nimbly_fee_amount), 0)           as nimbly_fee_amount
        , coalesce(sum(nimbly_commission_amount), 0)    as nimbly_commission_amount
        , coalesce(sum(wholesale_amount), 0)            as wholesale_amount
        , coalesce(sum(nimbly_fee_amount_usd), 0)       as nimbly_fee_amount_usd
        , coalesce(sum(nimbly_commission_amount_usd), 0) as nimbly_commission_amount_usd
        , coalesce(sum(wholesale_amount_usd), 0)        as wholesale_amount_usd
        , coalesce(sum(custom_print_fee_amount), 0)     as custom_print_fee_amount
        , coalesce(sum(custom_print_fee_amount_usd), 0) as custom_print_fee_amount_usd
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
        , coalesce(sum(moving_avg_cost_amount), 0)                   as moving_avg_cost_amount
        , coalesce(sum(net_sales_amount_usd), 0)        as net_sales_amount_usd
        , coalesce(sum(nimbly_fee_amount), 0)           as nimbly_fee_amount
        , coalesce(sum(nimbly_commission_amount), 0)    as nimbly_commission_amount
        , coalesce(sum(wholesale_amount), 0)            as wholesale_amount
        , coalesce(sum(nimbly_fee_amount_usd), 0)       as nimbly_fee_amount_usd
        , coalesce(sum(nimbly_commission_amount_usd), 0) as nimbly_commission_amount_usd
        , coalesce(sum(wholesale_amount_usd), 0)        as wholesale_amount_usd
        , coalesce(sum(custom_print_fee_amount), 0)     as custom_print_fee_amount
        , coalesce(sum(custom_print_fee_amount_usd), 0) as custom_print_fee_amount_usd
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

union all

select
      'net_sales_amount_usd'
    , cast(v.net_sales_amount_usd as decimal(38,6))
    , cast(f.net_sales_amount_usd as decimal(38,6))
from view_totals v
cross join fact_totals f
where v.net_sales_amount_usd <> f.net_sales_amount_usd

union all

select
      'nimbly_fee_amount'
    , cast(v.nimbly_fee_amount as decimal(38,6))
    , cast(f.nimbly_fee_amount as decimal(38,6))
from view_totals v
cross join fact_totals f
where v.nimbly_fee_amount <> f.nimbly_fee_amount

union all

select
      'nimbly_commission_amount'
    , cast(v.nimbly_commission_amount as decimal(38,6))
    , cast(f.nimbly_commission_amount as decimal(38,6))
from view_totals v
cross join fact_totals f
where v.nimbly_commission_amount <> f.nimbly_commission_amount

union all

select
      'wholesale_amount'
    , cast(v.wholesale_amount as decimal(38,6))
    , cast(f.wholesale_amount as decimal(38,6))
from view_totals v
cross join fact_totals f
where v.wholesale_amount <> f.wholesale_amount

union all

select
      'nimbly_fee_amount_usd'
    , cast(v.nimbly_fee_amount_usd as decimal(38,6))
    , cast(f.nimbly_fee_amount_usd as decimal(38,6))
from view_totals v
cross join fact_totals f
where v.nimbly_fee_amount_usd <> f.nimbly_fee_amount_usd

union all

select
      'nimbly_commission_amount_usd'
    , cast(v.nimbly_commission_amount_usd as decimal(38,6))
    , cast(f.nimbly_commission_amount_usd as decimal(38,6))
from view_totals v
cross join fact_totals f
where v.nimbly_commission_amount_usd <> f.nimbly_commission_amount_usd

union all

select
      'wholesale_amount_usd'
    , cast(v.wholesale_amount_usd as decimal(38,6))
    , cast(f.wholesale_amount_usd as decimal(38,6))
from view_totals v
cross join fact_totals f
where v.wholesale_amount_usd <> f.wholesale_amount_usd

union all

select
      'custom_print_fee_amount'
    , cast(v.custom_print_fee_amount as decimal(38,6))
    , cast(f.custom_print_fee_amount as decimal(38,6))
from view_totals v
cross join fact_totals f
where v.custom_print_fee_amount <> f.custom_print_fee_amount

union all

select
      'custom_print_fee_amount_usd'
    , cast(v.custom_print_fee_amount_usd as decimal(38,6))
    , cast(f.custom_print_fee_amount_usd as decimal(38,6))
from view_totals v
cross join fact_totals f
where v.custom_print_fee_amount_usd <> f.custom_print_fee_amount_usd

union all

select
      'moving_avg_cost_amount'
    , cast(v.moving_avg_cost_amount as decimal(38,6))
    , cast(f.moving_avg_cost_amount as decimal(38,6))
from view_totals v
cross join fact_totals f
where v.moving_avg_cost_amount <> f.moving_avg_cost_amount