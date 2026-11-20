{% macro union_scd2_history(history_relation, current_relation, key_column='Id') -%}
{#- Unions a frozen SCD2 history copy with a live SCD2 table that started fresh. History versions that start
    at or after a key's first live version are dropped, and the last kept one is closed at that start. -#}
{%- if execute -%}
    {%- set cur_cols = adapter.get_columns_in_relation(current_relation) -%}
    {%- set his_cols = adapter.get_columns_in_relation(history_relation) -%}
{%- else -%}
    {%- set cur_cols = [] -%}
    {%- set his_cols = [] -%}
{%- endif -%}
{%- set his_lookup = {} -%}
{%- for c in his_cols -%}{%- do his_lookup.update({c.name | lower: c}) -%}{%- endfor -%}
{%- set cur_lookup = {} -%}
{%- for c in cur_cols -%}{%- do cur_lookup.update({c.name | lower: c}) -%}{%- endfor -%}
{%- set all_cols = [] -%}
{%- for c in cur_cols -%}{%- do all_cols.append(c) -%}{%- endfor -%}
{%- for c in his_cols -%}{%- if (c.name | lower) not in cur_lookup -%}{%- do all_cols.append(c) -%}{%- endif -%}{%- endfor -%}
WITH cur AS (
    SELECT c.* FROM {{ current_relation }} c
),
first_cur AS (
    SELECT
          c.`{{ key_column }}` AS key_value
        , MIN(c.`__START_AT`) AS first_start_at
    FROM cur c
    GROUP BY c.`{{ key_column }}`
),
his AS (
    SELECT
          h.*
        , f.first_start_at
    FROM {{ history_relation }} h
    LEFT JOIN first_cur f
        ON f.key_value = h.`{{ key_column }}`
    WHERE f.first_start_at IS NULL
       OR h.`__START_AT` < f.first_start_at
)
SELECT
{%- for c in all_cols %}
    {{ ',' if not loop.first else ' ' }} {% if (c.name | lower) == '__end_at' -%}
        CASE
            WHEN h.first_start_at IS NOT NULL
             AND (h.`__END_AT` IS NULL OR h.`__END_AT` > h.first_start_at) THEN h.first_start_at
            ELSE h.`__END_AT`
        END AS `__END_AT`
    {%- elif (c.name | lower) in his_lookup -%}
        CAST(h.`{{ his_lookup[c.name | lower].name }}` AS {{ c.data_type }}) AS `{{ c.name }}`
    {%- else -%}
        CAST(NULL AS {{ c.data_type }}) AS `{{ c.name }}`
    {%- endif -%}
{%- endfor %}
    , 'pre_cutover' AS row_source
FROM his h
UNION ALL
SELECT
{%- for c in all_cols %}
    {{ ',' if not loop.first else ' ' }} {% if (c.name | lower) in cur_lookup -%}
        c.`{{ cur_lookup[c.name | lower].name }}`
    {%- else -%}
        CAST(NULL AS {{ c.data_type }}) AS `{{ c.name }}`
    {%- endif -%}
{%- endfor %}
    , 'phoenix_raw' AS row_source
FROM cur c
{%- endmacro %}
