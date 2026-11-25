{% macro union_bigcommerce_stores(table_name, columns, has_deleted_flag=true) %}
{#-
    Unions one BigCommerce table across the live stores in var('bigcommerce_stores'),
    adding store_code (upper-cased store suffix). Columns are listed by name so a
    store schema with a different column order still lines up. Each store needs a
    bronze_bigcommerce_<store>_<table> model. Rows Fivetran marks deleted are dropped
    when the table carries _fivetran_deleted.
-#}
{%- for store in var('bigcommerce_stores') %}
    SELECT
          '{{ store | upper }}' AS store_code
        {%- for c in columns %}
        , b.{{ c }}
        {%- endfor %}
    FROM {{ ref('bronze_bigcommerce_' ~ store ~ '_' ~ table_name) }} b
    {%- if has_deleted_flag %}
    WHERE NOT COALESCE(b._fivetran_deleted, false)
    {%- endif %}
    {%- if not loop.last %}
    UNION ALL
    {%- endif %}
{%- endfor %}
{% endmacro %}
