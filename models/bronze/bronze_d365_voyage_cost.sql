{{ config(materialized = 'view') }}

SELECT
    *
FROM
    {{source("byod","d365_voyage_cost")}}
