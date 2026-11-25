{{ config(materialized = 'view') }}

SELECT
    s.*
FROM
    {{ source('SFDC', 'sfdc_bc_order_c') }} s
