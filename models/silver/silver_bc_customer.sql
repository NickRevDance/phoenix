{{ config(materialized = 'table') }}

SELECT
    c.*
    , g.description AS customer_group_description
FROM
    {{ ref("bronze_bc_customer") }} c
LEFT JOIN
    {{ ref("bronze_bc_customer_group") }} g
    ON c.store = g.store
    AND c.customer_group_id = g.bc_id
