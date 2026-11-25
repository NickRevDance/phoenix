{{ config(materialized = 'view') }}

SELECT
    s.*
FROM
    {{ source('bigcommerce_ca', 'customer_group') }} s
