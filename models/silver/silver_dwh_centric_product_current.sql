{{ config(materialized = 'table') }}

SELECT
     CPC.*
    ,REPLACE(CPC.StyleSKU, '-', '|') AS SKU
    ,CONCAT(CPC.`Style#`, '|', CPC.Colorway) AS CodeColor
    ,CASE
        WHEN CPC.ThirdParty THEN 'ThirdParty'
        ELSE 'Owned'
     END AS ProductOwnership
FROM
    {{ ref('bronze_dwh_centric_product') }} CPC
WHERE
    CPC.D365ProductSetup = 'Completed'
    AND CPC.IsCurrent
-- Centric can carry two current records for one UPC that differ only in OriginalSeason; keep the earliest season.
QUALIFY ROW_NUMBER() OVER (PARTITION BY CPC.UPC ORDER BY CPC.OriginalSeason ASC, CPC.CentricProductDimId DESC) = 1
