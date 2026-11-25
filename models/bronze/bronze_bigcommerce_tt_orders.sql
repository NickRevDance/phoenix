{{ config(materialized = 'view') }}

SELECT
    s.*
FROM
    {{ source('bigcommerce_tt', 'orders') }} s
