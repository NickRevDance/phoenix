{{ config(materialized = 'view') }}

SELECT
    *
FROM
    {{ source('byod', 'd365_product_variant') }}
