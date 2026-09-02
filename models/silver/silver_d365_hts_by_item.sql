{{ config(materialized = 'table') }}

SELECT
     ItemID
    ,STRING_AGG(
        CONCAT(
             HTSCode
            ,'|'
            ,HTSDuty
            ,'|'
            ,CAST((Composition * 100) AS INT)
            ,'%'
        )
        ,','
     ) AS HTSCodeDutyComposition
    ,MAX(ModifiedDate) AS ModifiedDate
FROM
    {{ ref('bronze_d365_hts_assignment') }}
WHERE
    HTSType = 1
GROUP BY
    ItemID