{{ config(materialized = 'table') }}

{% if empty_extract_guard(ref('bronze_d365_logistics_electronic_address'), 1) %}

SELECT
    *
FROM
    {{ this }}

{% else %}

SELECT
    *
FROM
    {{ ref('bronze_d365_logistics_electronic_address') }}

{% endif %}
