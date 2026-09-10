{{ config(materialized = 'view') }}

SELECT
    *
FROM
    {{ source('byod', 'd365_invent_transfer_line') }}
