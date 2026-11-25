{{ config(materialized = 'view') }}

SELECT
    s.*
FROM
    {{ source('bigcommerce_ca', 'product_variant') }} s
