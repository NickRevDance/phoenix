{{ config(materialized = 'view') }}

SELECT
    s.*
FROM
    {{ source('bigcommerce_ca', 'order_refund_item') }} s
