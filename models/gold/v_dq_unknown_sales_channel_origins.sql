{{ config(materialized = 'view') }}

with fact_sales_invoice_unknown as (

    select
          'fact_sales_invoice' as fact_name
        , source_sales_origin_id
        , count(*) as row_count

    from {{ ref('fact_sales_invoice') }}
    where sales_channel_key = -1
    group by source_sales_origin_id

),

fact_order_line_unknown as (

    select
          'fact_order_line' as fact_name
        , source_sales_origin_id
        , count(*) as row_count

    from {{ ref('fact_order_line') }}
    where sales_channel_key = -1
    group by source_sales_origin_id

),

unioned as (

    select * from fact_sales_invoice_unknown
    union all
    select * from fact_order_line_unknown

)

select * from unioned
order by fact_name, row_count desc
