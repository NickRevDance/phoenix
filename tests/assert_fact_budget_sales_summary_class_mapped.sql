{{ config(severity = 'warn') }}

-- EDW-71 DQ exception report: budget summary classes not in the Finance class list (REF_SUMMARY_CLASS_ROLLUP) or with no current DIM_PRODUCT row, so actuals cannot roll up to them.
select
      f.summary_class
    , case when r.summary_class is null then 'not in ref_summary_class_rollup' else 'no current dim_product row' end as exception_reason
    , sum(f.budget_net_sales) as budget_net_sales
from {{ ref('fact_budget_sales') }} f
left join {{ ref('ref_summary_class_rollup') }} r
    on r.summary_class = f.summary_class
left join (
    select distinct p.summary_class from {{ ref('dim_product') }} p where p.version_number = 1
) p
    on p.summary_class = f.summary_class
where r.summary_class is null
   or p.summary_class is null
group by 1, 2
