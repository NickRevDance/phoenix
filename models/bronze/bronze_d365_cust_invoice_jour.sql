{{ config(materialized = 'view') }}

SELECT
    *
FROM
    {{source("byod","d365_cust_invoice_jour")}}
