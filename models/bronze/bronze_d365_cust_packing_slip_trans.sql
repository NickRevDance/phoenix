{{ config(materialized = 'view') }}

SELECT
    src.*
FROM
    {{ source('byod', 'd365_cust_packing_slip_trans') }} src
