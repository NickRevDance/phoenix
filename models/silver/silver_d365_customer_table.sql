{{ config(materialized = 'table') }}
 
SELECT
    *
FROM
    {{ ref("bronze_d365_customer_table") }}
 