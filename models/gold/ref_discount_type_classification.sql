{{ config(materialized = 'table', schema = 'shared_gold') }}

with final as (

    select

          {{ generate_surrogate_key(['c.discount_type', 'c.effective_start_date']) }} as discount_type_classification_key
        , c.discount_type
        , c.reduces_net_sales_flag = 'true' as reduces_net_sales_flag
        , c.expense_treatment
        , cast(c.effective_start_date as date) as effective_start_date
        , nullif(c.note, '') as note
        , current_timestamp() as etl_insert_datetime

    from {{ ref('discount_type_classification') }} c

)

select * from final
