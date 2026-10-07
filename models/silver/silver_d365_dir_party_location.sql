{{ config(materialized = 'table') }}

{% if empty_extract_guard(ref('bronze_d365_dir_party_location'), 1) %}

SELECT
    *
FROM
    {{ this }}

{% else %}

SELECT
    *
FROM
    {{ ref('bronze_d365_dir_party_location') }}

{% endif %}
