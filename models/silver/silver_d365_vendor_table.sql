{{ config(materialized = 'table') }}

SELECT
    *
FROM
    {{ref("bronze_d365_vendor_table")}}