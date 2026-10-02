{{ config(severity = 'warn') }}
 
-- EDW-125: every summary class produced by ref_product_summary_class has a row in
-- ref_summary_class_rollup. A class added to the product mapping returns here (warn) until
-- its rollup row is added; on the dimension its products read Other in the meantime.
select
      p.summary_class
    , count(*) as mapping_rows
from {{ ref('ref_product_summary_class') }} p
left join {{ ref('ref_summary_class_rollup') }} r
    on r.summary_class = p.summary_class
where p.summary_class is not null
  and r.summary_class is null
group by p.summary_class
 