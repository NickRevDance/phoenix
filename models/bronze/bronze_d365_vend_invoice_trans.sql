{{ config(materialized = 'view') }}

SELECT
    *
FROM
    {{ source('byod', 'd365_vend_invoice_trans') }}
