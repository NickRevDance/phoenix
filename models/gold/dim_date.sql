{{ config(materialized = 'table') }}

SELECT
    d.*
FROM
    {{ref("silver_dim_date")}} d