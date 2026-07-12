{{ config(materialized = 'table') }}

SELECT
     DisplayProductNumber
    ,ProductClass
    ,RecID
    ,ModifiedDate
FROM
    {{ ref('bronze_byod_product_variant') }}