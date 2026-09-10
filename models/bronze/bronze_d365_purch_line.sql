{{ config(materialized = 'view') }}

SELECT
    *
FROM
    {{ source('byod', 'd365_purch_line') }}
