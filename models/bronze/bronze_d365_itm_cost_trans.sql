{{ config(materialized = 'view') }}

SELECT
    *
FROM
    {{ source('byod', 'itm_cost_trans') }}