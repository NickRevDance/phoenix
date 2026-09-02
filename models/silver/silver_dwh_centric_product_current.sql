{{ config(materialized = 'table') }}

SELECT
     *
    ,REPLACE(StyleSKU, '-', '|') AS SKU
    ,CONCAT(`Style#`, '|', Colorway) AS CodeColor
    ,CASE
        WHEN ThirdParty THEN 'ThirdParty'
        ELSE 'Owned'
     END AS ProductOwnership
FROM
    {{ ref('bronze_dwh_centric_product') }}
WHERE
    D365ProductSetup = 'Completed'
    AND IsCurrent