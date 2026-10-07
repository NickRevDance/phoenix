{{ config(materialized = 'view') }}

-- V_METRICS_SALES_DAILY (EDW-133; FACT_SALES_INVOICE spec Section 9 and the shape section of
-- September 21 2026). The certified daily sales metrics view over FACT_SALES_INVOICE.
-- Grain: one row per invoice_date_key + product_key + customer_key + sales_channel_key +
-- warehouse_key + transaction_currency_code + invoice_type.
-- Coverage: every row of the fact is represented, including unresolved keys and Free Text
-- lines, so each additive measure summed over the view equals the same sum over the fact
-- (tests/assert_v_metrics_sales_daily_ties_to_fact.sql).
-- Ratios: every ratio ships as its numerator and denominator and is never pre-divided here.
-- ASP, discount rate, margin percent and return rate are divided by the consumer.
-- Currency: transaction amounts are in transaction_currency_code. Never sum them across
-- currencies. Standard cost is carried in cost_currency_code (USD on every line today), so the
-- margin and below-cost measures are computed only on lines where the two currencies match
-- and are NULL on the others (the CAD lines) until the USD amounts land with EDW-169.
-- invoice_type: taken from the fact once EDW-59 populates it. Until then it is derived from
-- order_id, which is blank (never NULL) on free text invoice lines.
-- Free Text: kept as their own rows so totals reconcile to the AR ledger. Revenue and
-- discount totals include both types; anything by product, units, ASP, cost or margin filters
-- invoice_type = 'Sales Order'.
-- Returns: credit lines net into the same row as sales for the key and are also broken out
-- as return_qty and return_amount (positive values).
-- Below cost (EDW-146): a line is below cost when standard_cost_unit >= unit_price. Reported
-- as-is beside the unfiltered margin, never excluded. Zero-price lines with a cost count here.
-- Dimension attributes: the latest version of each dimension row (version_number = 1), so a
-- member that has since been closed at the source still describes its history. They are
-- carried so the view reads on its own in Excel and SQL; Power BI relates on the keys.
-- Typed NULL columns (D6) hold their place in the contract: landed and freight cost (EDW-60),
-- net_sales_amount_usd (EDW-169), loyalty_points_earned (EDW-78).
-- warehouse_key is NULL where the line resolves to no warehouse (the Free Text lines and a
-- few others) until DIM_WAREHOUSE carries its unknown member (EDW-90).

with invoice_line as (

    select

          f.invoice_date_key
        , f.invoice_date
        , f.product_key
        , f.customer_key
        , f.sales_channel_key
        , f.warehouse_key
        , f.transaction_currency_code
        , coalesce(
              f.invoice_type
            , case when nullif(f.order_id, '') is null then 'Free Text' else 'Sales Order' end
          )                                                          as invoice_type
        , f.invoice_id
        , f.invoiced_qty
        , f.gross_sales_amount
        , f.line_discount_amount
        , f.header_discount_allocated
        , f.total_discount_amount
        , f.net_sales_amount
        , f.tax_amount
        , f.standard_cost_amount
        , f.cost_currency_code
        , f.is_return_flag
        , case when f.standard_cost_unit is not null
                and f.cost_currency_code = f.transaction_currency_code
               then 1 else 0
          end                                                        as has_comparable_cost
        , case when f.standard_cost_unit >= f.unit_price then 1 else 0 end as is_below_cost

    from {{ ref('fact_sales_invoice') }} f

),

daily as (

    select

          l.invoice_date_key
        , l.product_key
        , l.customer_key
        , l.sales_channel_key
        , l.warehouse_key
        , l.transaction_currency_code
        , l.invoice_type
        , max(l.invoice_date)                                        as invoice_date
        , max(l.cost_currency_code)                                  as cost_currency_code

        , count(*)                                                   as invoice_line_count
        , count(distinct l.invoice_id)                               as invoice_count

        , {{ amount('sum(l.invoiced_qty)') }}                        as invoiced_qty
        , {{ amount('sum(l.gross_sales_amount)') }}                  as gross_sales_amount
        , {{ amount('sum(l.line_discount_amount)') }}                as line_discount_amount
        , {{ amount('sum(l.header_discount_allocated)') }}           as header_discount_allocated
        , {{ amount('sum(l.total_discount_amount)') }}               as total_discount_amount
        , {{ amount('sum(l.net_sales_amount)') }}                    as net_sales_amount
        , {{ amount('sum(l.tax_amount)') }}                          as tax_amount

        , {{ amount('sum(l.standard_cost_amount)') }}                as standard_cost_amount
        , {{ amount('sum(case when l.has_comparable_cost = 1 then l.net_sales_amount end)') }}
                                                                     as net_sales_amount_with_cost
        , {{ amount('sum(case when l.has_comparable_cost = 1 then l.net_sales_amount - l.standard_cost_amount end)') }}
                                                                     as gross_margin_std_amount

        , {{ amount('sum(case when l.is_return_flag then abs(l.invoiced_qty) else 0 end)') }}
                                                                     as return_qty
        , {{ amount('sum(case when l.is_return_flag then abs(l.net_sales_amount) else 0 end)') }}
                                                                     as return_amount

        , sum(case when l.has_comparable_cost = 1 then l.is_below_cost end)
                                                                     as below_cost_line_count
        , {{ amount('sum(case when l.has_comparable_cost = 1 and l.is_below_cost = 1 then l.net_sales_amount when l.has_comparable_cost = 1 then 0 end)') }}
                                                                     as below_cost_net_sales_amount
        , {{ amount('sum(case when l.has_comparable_cost = 1 and l.is_below_cost = 1 then l.standard_cost_amount when l.has_comparable_cost = 1 then 0 end)') }}
                                                                     as below_cost_standard_cost_amount

    from invoice_line l

    group by
          l.invoice_date_key
        , l.product_key
        , l.customer_key
        , l.sales_channel_key
        , l.warehouse_key
        , l.transaction_currency_code
        , l.invoice_type

),

date_dim as (

    select
          date_key
        , fiscal_year
        , fiscal_quarter
        , fiscal_month
        , fiscal_year_week
        , year_month_int
    from {{ ref('dim_date') }}

),

product as (

    select
          product_key
        , product_id
        , style_number
        , style_name
        , summary_class
        , product_group
        , reporting_category_group
        , reporting_subcategory
        , dw_sku_status
    from {{ ref('dim_product') }}
    where version_number = 1

),

customer as (

    select
          customer_key
        , customer_type
        , customer_status
    from {{ ref('dim_customer') }}
    where version_number = 1

),

channel as (

    select
          sales_channel_key
        , channel_code
        , channel_name
        , channel_type
        , storefront_code
    from {{ ref('dim_sales_channel') }}

),

warehouse as (

    select
          warehouse_key
        , warehouse_id
    from {{ ref('dim_warehouse') }}
    where version_number = 1

)

select

    -- Grain
      d.invoice_date_key
    , d.product_key
    , d.customer_key
    , d.sales_channel_key
    , d.warehouse_key
    , d.transaction_currency_code
    , d.invoice_type

    -- Date attributes
    , d.invoice_date
    , dt.fiscal_year
    , dt.fiscal_quarter
    , dt.fiscal_month
    , dt.fiscal_year_week
    , dt.year_month_int

    -- Product attributes
    , pr.product_id
    , pr.style_number
    , pr.style_name
    , pr.summary_class
    , pr.product_group
    , pr.reporting_category_group
    , pr.reporting_subcategory
    , pr.dw_sku_status

    -- Customer attributes
    , cu.customer_type
    , cu.customer_status

    -- Sales channel attributes
    , ch.channel_code
    , ch.channel_name
    , ch.channel_type
    , ch.storefront_code

    -- Warehouse attributes
    , wh.warehouse_id

    -- Volume
    , d.invoice_line_count
    , d.invoice_count
    , d.invoiced_qty

    -- Revenue (transaction currency)
    , d.gross_sales_amount
    , d.line_discount_amount
    , d.header_discount_allocated
    , d.total_discount_amount
    , d.net_sales_amount
    , d.tax_amount

    -- Standard cost and margin
    , d.cost_currency_code
    , d.standard_cost_amount
    , d.net_sales_amount_with_cost
    , d.gross_margin_std_amount

    -- Returns
    , d.return_qty
    , d.return_amount

    -- Below cost (EDW-146)
    , d.below_cost_line_count
    , d.below_cost_net_sales_amount
    , d.below_cost_standard_cost_amount

    -- Held for later builds (typed NULL, D6)
    , cast(null as decimal(38,6)) as landed_cost_amount          -- EDW-60
    , cast(null as decimal(38,6)) as gross_margin_landed_amount  -- EDW-60
    , cast(null as decimal(38,6)) as freight_cost_amount         -- EDW-60
    , cast(null as decimal(38,6)) as net_sales_amount_usd        -- EDW-169
    , cast(null as decimal(38,6)) as loyalty_points_earned       -- EDW-78

from daily d

left join date_dim dt
    on d.invoice_date_key = dt.date_key

left join product pr
    on d.product_key = pr.product_key

left join customer cu
    on d.customer_key = cu.customer_key

left join channel ch
    on d.sales_channel_key = ch.sales_channel_key

left join warehouse wh
    on d.warehouse_key = wh.warehouse_key