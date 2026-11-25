{{ config(materialized = 'view') }}

SELECT
    s.*
FROM
    {{ source('SFDC', 'sfdc_bc_product_c') }} s
