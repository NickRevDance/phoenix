{{ config(materialized = 'table') }}

SELECT
     b.SaleDate
    ,TRIM(b.SummaryClass) AS SummaryClass
    ,CAST(b.Budget AS DECIMAL(18,2)) AS Budget    
    ,COALESCE(CAST(b.BudgetQty AS DECIMAL(18,4)), 0) AS BudgetQty  -- 2027-01-31 lands with $0 budget and NULL qty on every class
    ,b.ETLImportDate
FROM
    {{ ref('bronze_dwh_budget_sales_summary_class') }} b
WHERE
    b.SaleDate IS NOT NULL
    AND NULLIF(TRIM(b.SummaryClass), '') IS NOT NULL
