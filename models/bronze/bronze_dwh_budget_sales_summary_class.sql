{{ config(materialized = 'view') }}

select * from {{ source('dwhvisualnext', 'budget_sales_summary_class') }}
