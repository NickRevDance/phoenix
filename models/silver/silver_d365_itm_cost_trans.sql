{{ config(materialized = 'table') }}

SELECT
    *
FROM
    {{ref("bronze_d365_itm_cost_trans")}}