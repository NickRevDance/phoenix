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

{% macro scd2_is_current_row(version_number_col='version_number') %}
{#-
    Project-standard is_current_row column: int 1/0 (NOT boolean --
    this was flagged as a live divergence between dim_product/dim_vendor
    (int) and dim_warehouse (boolean) in the EDW-10 sign-off review;
    int 1/0 is the majority/documented convention this macro locks in).
    Relies on Databricks/Spark's lateral column alias support to
    reference version_number in the same select list -- same pattern
    already live in dim_product.sql and dim_vendor.sql.
-#}
case when {{ version_number_col }} = 1 then 1 else 0 end
{%- endmacro %}
