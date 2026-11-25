{{ config(materialized = 'view') }}

SELECT
    s.*
FROM
    {{ source('bigcommerce_us', 'order_refund') }} s
