{{ config(materialized = 'view') }}

SELECT
    *
FROM
    {{ source('byod', 'product_variant') }}