{{ config(materialized = 'view') }}

SELECT
    *
FROM
    {{ source('byod', 'purch_line') }}
