-- Size-run internals hang together: in-stock counts never exceed totals, completeness = core in stock / core total,
-- the broken flag follows completeness, and a score exists exactly when a rule set matched.

select
      q.inventory_quality_key
    , q.size_count_total
    , q.size_count_in_stock
    , q.core_size_count_total
    , q.core_size_count_in_stock
    , q.core_size_completeness_pct
    , q.broken_size_run_flag
    , q.inventory_quality_score

from {{ ref('fact_inventory_quality_code_color_daily') }} q
where q.size_count_in_stock > q.size_count_total
   or q.core_size_count_in_stock > q.core_size_count_total
   or q.core_size_count_total > q.size_count_total
   or (q.core_size_count_total > 0 and abs(q.core_size_completeness_pct - round(q.core_size_count_in_stock / q.core_size_count_total, 4)) > 0.0001)
   or (q.core_size_completeness_pct = 1 and q.broken_size_run_flag <> 0)
   or (q.core_size_completeness_pct < 1 and q.broken_size_run_flag <> 1)
   or ((q.size_count_total > 0) <> (q.inventory_quality_score is not null))
