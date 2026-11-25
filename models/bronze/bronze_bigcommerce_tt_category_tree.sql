{{ config(materialized = 'view') }}

SELECT
    s.*
FROM
    {{ source('bigcommerce_tt', 'category_tree') }} s
