{{ config(materialized = 'view') }}

SELECT
    *
FROM
    {{source("byod","voyage_cost")}}
