{{ config(materialized = 'table') }}

SELECT
    d.*
FROM
    {{ref("bronze_dim_date")}} d