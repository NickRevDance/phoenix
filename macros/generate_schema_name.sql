{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- set default_schema = target.schema -%}
    {#- If a custom schema is provided and we are in production, use ONLY the custom schema name -#}
    {%- if custom_schema_name is not none and target.name == 'prod' -%}
        {{ custom_schema_name | trim }}
    {#- Otherwise, default to standard development appending logic -#}
    {%- else -%}
        {{ default_schema }}_{{ custom_schema_name | trim if custom_schema_name is not none else '' }}
    {%- endif -%}
{%- endmacro %}
