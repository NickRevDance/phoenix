{{ config(materialized = 'table') }}

SELECT
    b.*
FROM
    {{ ref('bronze_sfdc_chargent_orders_chargent_order_c') }} b
