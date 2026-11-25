{{ config(materialized = 'view') }}

SELECT
    s.*
FROM
    {{ source('bigcommerce_us', 'customer_group') }} s
