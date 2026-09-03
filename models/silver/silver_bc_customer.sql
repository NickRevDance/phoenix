{{ config(materialized = 'table') }}
 
SELECT
    *
FROM
    {{ ref("bronze_bc_customer") }}
 