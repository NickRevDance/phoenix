{{ config(materialized = 'table') }}

SELECT
    xxhash64(concat_ws('|', t.brand, t.product_group, t.product_sub_group)) AS product_summary_class_key
    ,t.brand
    ,t.product_group
    ,t.product_sub_group
    ,t.summary_class
    ,t.classification_owner
    ,t.classified_date
    ,t.notes

FROM {{ ref('product_summary_class_map') }} t
