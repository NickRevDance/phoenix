{% macro generate_surrogate_key(column_list) %}
{#-
    Project-standard surrogate-key recipe (EDW-8 guardrail 1: one key
    recipe, one shared macro, instead of xxhash64/md5 reinvented per
    model). Databricks-native xxhash64 -> bigint, hashing only the
    stable natural/business-key columns passed in -- never a Type 2
    (SCD2-tracked) attribute, so the key stays stable across future
    versions of the same entity.

    This macro does NOT produce reserved/unknown-member keys (0 / -1)
    -- xxhash64 can't be coerced to land on a specific value. Reserved
    members are hardcoded literals unioned in separately by the calling
    model; see unknown_member_key() / default_member_key() in
    reserved_dimension_members.sql.
-#}
xxhash64({{ column_list | join(', ') }})
{%- endmacro %}
