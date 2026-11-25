{{ config(materialized = 'view') }}

SELECT
    s.*
FROM
    {{ source('bigcommerce_tt', 'customer_group') }} s
