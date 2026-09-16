{% macro generate_row_hash(column_list) %}
{#-
    Project-standard SCD2 change-hash recipe. Pass a list of already
    cast/coalesced SQL expressions -- one per Type-2-tracked attribute,
    typically `coalesce(cast(col as string), '')` -- and this macro
    centralizes the hash function/delimiter so every model doesn't
    reinvent sha2(concat_ws(...), 256) with a slightly different
    delimiter or hash length. Column selection (which attributes are
    Type 2) stays with the calling model -- that's a per-table business
    decision, not something a shared macro should hide.
-#}
sha2(concat_ws('||', {{ column_list | join(', ') }}), 256)
{%- endmacro %}
