{{ config(materialized = 'view') }}

SELECT
    *
FROM
    {{ source('byod', 'd365_itm_cost_trans') }}
