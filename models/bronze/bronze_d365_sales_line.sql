{{ config(materialized = 'view') }}

SELECT
    *
FROM
    {{source("byod","d365_sales_line")}}
