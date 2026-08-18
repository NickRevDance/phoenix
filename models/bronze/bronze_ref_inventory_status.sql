{{ config(materialized = 'view') }}

SELECT
    *
FROM
    {{ source("refs", "ref_inventory_status") }}