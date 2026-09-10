{{ config(materialized = 'view') }}

SELECT
    *
FROM
    {{ source('byod', 'invent_transfer_line') }}
