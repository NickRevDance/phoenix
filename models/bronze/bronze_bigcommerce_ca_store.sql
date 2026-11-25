{{ config(materialized = 'view') }}

SELECT
    s.*
FROM
    {{ source('bigcommerce_ca', 'store') }} s
