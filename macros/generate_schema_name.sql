{# macros/generate_schema_name.sql #}

{% macro generate_schema_name(custom_schema_name, node) -%}
    {# If we are in production, output exactly the custom schema name (e.g., 'silver') #}
    {%- if target.name == 'prod' or target.name == 'production' -%}
        {{ custom_schema_name | trim }}
    
    {# If we are in development, append the custom schema to the developer's custom schema prefix to isolate their work #}
    {%- else -%}
        {%- if custom_schema_name is none -%}
            {{ target.schema }}
        {%- else -%}
            {{ target.schema }}_{{ custom_schema_name | trim }}
        {%- endif -%}
    {%- endif -%}
{%- endmacro %}
