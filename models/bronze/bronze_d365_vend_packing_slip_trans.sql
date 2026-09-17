{{ config(materialized = 'view') }}

SELECT
    *
FROM
    {{ source('byod', 'd365_vend_packing_slip_trans') }}
