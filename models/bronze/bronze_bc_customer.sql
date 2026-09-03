{{ config(materialized = 'view') }}
 
SELECT
    *
FROM
    {{source("bc","bc_customer")}}
 