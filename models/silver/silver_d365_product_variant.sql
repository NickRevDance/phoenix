{{ config(materialized = 'table') }}

SELECT
     DisplayProductNumber
    ,ProductClass
    ,RecID
    ,ModifiedDate
FROM
    {{ ref('bronze_d365_product_variant') }}