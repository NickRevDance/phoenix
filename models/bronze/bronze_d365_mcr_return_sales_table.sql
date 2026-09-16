{{ config(materialized = 'view') }}

SELECT
    *
FROM
    {{source("byod","d365_mcr_return_sales_table")}}
