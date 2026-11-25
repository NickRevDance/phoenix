{{ config(materialized = 'view') }}

SELECT
    s.*
FROM
    {{ source('bigcommerce_us', 'product_category') }} s
