{% macro amount(expression) %}
{#-
    Project-standard monetary/quantity decimal type -- decimal(38,6),
    Databricks' max total precision at our established scale of 6.
    Wrap every computed (not straight-passthrough-typed) amount column
    in this macro instead of hand-reasoning Spark's decimal-widening
    rules (mult: precision = p1+p2; add: precision = max(p1-s1,p2-s2)+
    max(s1,s2)+1) or hardcoding a cast per column.

    Why this exists (EDW-23, 2026-09-16): fact_order_line/fact_sales_invoice
    are incremental/merge models. Delta's ALTER TABLE CHANGE COLUMN does
    not support changing a column's decimal precision -- not widening,
    not narrowing. Every time an amount formula changes (e.g. LINEDISC
    per-unit fix, LINEAMOUNT-as-source-of-truth fix) Spark infers a
    different result precision than whatever got persisted on the first
    run, and the merge fails with DELTA_UNSUPPORTED_ALTER_TABLE_CHANGE_COL_OP.
    Pinning every computed amount to one fixed, generous type up front
    means a future formula edit can change *values* without ever again
    changing the *column type* -- no more chasing this error column by
    column. 38,6 comfortably covers every amount/qty in this project
    (source columns top out at decimal(32,6)) with room to spare.

    One-time cost: harmonizing an already-live column to this type still
    needs a single --full-refresh (Delta can't ALTER into it either) --
    but only once per column, not once per future formula tweak.
-#}
cast({{ expression }} as decimal(38,6))
{%- endmacro %}
