{{ config(materialized = 'view') }}

SELECT
    s.*
FROM
    {{ source('bigcommerce_tt', 'product') }} s
