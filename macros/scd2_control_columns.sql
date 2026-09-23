{% macro scd2_version_number(partition_by, order_by='effective_start_datetime') %}
{#-
    Project-standard SCD2 version-number column: latest version = 1,
    per the dim_product/dim_vendor/dim_customer precedent. Requires the
    calling model to already carry effective_start_datetime (the
    remapped dbt snapshot dbt_valid_from column) or an equivalent
    ordering column passed via order_by.
-#}
row_number() over (partition by {{ partition_by }} order by {{ order_by }} desc)
{%- endmacro %}

{% macro scd2_is_current_row(version_number_col='version_number', end_datetime_col='effective_end_datetime') %}
{#-
    Project-standard is_current_row column: int 1/0 (NOT boolean --
    this was flagged as a live divergence between dim_product/dim_vendor
    (int) and dim_warehouse (boolean) in the EDW-10 sign-off review;
    int 1/0 is the majority/documented convention this macro locks in).
    Relies on Databricks/Spark's lateral column alias support to
    reference version_number in the same select list -- same pattern
    already live in dim_product.sql and dim_vendor.sql.

    EDW-91 (2026-09-22): current means latest version AND an open end
    date, not latest version alone. Every snapshot in the repo now runs
    hard_deletes: invalidate (EDW-8 house default, 2026-09-17), which
    closes the open version of a record that leaves the source without
    inserting a successor. That record still ranks version_number = 1,
    so a version-only test reports a deleted record as current. Rule per
    DIM_WAREHOUSE v1.2 and DIM_CUSTOMER v1.3. Reserved members carry a
    NULL effective_end_datetime and stay current, as intended.
-#}
case when {{ version_number_col }} = 1 and {{ end_datetime_col }} is null then 1 else 0 end
{%- endmacro %}