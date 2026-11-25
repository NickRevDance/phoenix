{{ config(materialized = 'view') }}

SELECT
    s.*
FROM
    {{ source('bigcommerce_tt', 'order_refund') }} s
