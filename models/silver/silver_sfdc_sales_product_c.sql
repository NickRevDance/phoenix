{{ config(materialized = 'table') }}

SELECT
    b.*
FROM
    {{ ref('bronze_sfdc_sales_product_c') }} b
