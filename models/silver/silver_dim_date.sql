{{ config(materialized = 'table') }}

SELECT
    d.*
FROM
    {{ref("bronze_dwh_dim_date")}} d