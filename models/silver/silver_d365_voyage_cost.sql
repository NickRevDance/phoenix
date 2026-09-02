{{ config(materialized = 'table') }}

SELECT
    *
FROM
    {{ref("bronze_d365_voyage_cost")}}