-- Certified gate (spec 4.3, F5): per invoice line, SUM(discount_amount) must equal total_discount_amount on the parent. Zero tolerance.
with fact_sum as (

    select

          d.sales_invoice_key
        , sum(d.discount_amount) as discount_amount_sum

    from {{ ref('fact_discount_application') }} d

    group by d.sales_invoice_key

)

select

      i.sales_invoice_key
    , i.total_discount_amount
    , coalesce(f.discount_amount_sum, 0) as discount_amount_sum

from {{ ref('fact_sales_invoice') }} i

left join fact_sum f
    on i.sales_invoice_key = f.sales_invoice_key

where coalesce(i.total_discount_amount, 0) <> coalesce(f.discount_amount_sum, 0)
