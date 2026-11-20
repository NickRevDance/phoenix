{{ config(materialized = 'table') }}

SELECT
    b.*
FROM
    {{ ref('bronze_sfdc_sales_order_c') }} b
