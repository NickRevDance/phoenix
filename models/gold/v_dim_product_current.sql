{{ config(materialized = 'view') }}

SELECT
    snap_p.* EXCEPT (product_change_hash)
FROM
    {{ref("dim_product")}} snap_p
WHERE
    version_number = 1