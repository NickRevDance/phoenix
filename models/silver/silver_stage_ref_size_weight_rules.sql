SELECT

      TRIM(rule_id)                                  AS rule_id
    , CAST(priority AS INT)                           AS priority
    , TRIM(product_group)                              AS product_group
    , TRIM(product_subgroup)                           AS product_subgroup
    , TRIM(gender)                                     AS gender
    , TRIM(adult_child)                                AS adult_child
    , TRIM(style)                                      AS style
    , TRIM(brand)                                      AS brand
    , TRIM(genre)                                      AS genre
    , TRIM(age_look)                                   AS age_look
    , TRIM(size)                                       AS size
    , CAST(size_weight AS DECIMAL(9,6))                 AS size_weight
    , CAST(size_rank AS INT)                            AS size_rank
    , CAST(NULLIF(TRIM(is_core_size), '') AS INT)        AS is_core_size
    , NULLIF(TRIM(size_system), '')                     AS size_system
    , CAST(NULLIF(TRIM(size_sort_order), '') AS INT)     AS size_sort_order
    , CAST(is_active AS INT)                            AS is_active
    , CAST(effective_start_date AS DATE)                 AS effective_start_date
    , CAST(effective_end_date AS DATE)                   AS effective_end_date
    , NULLIF(TRIM(notes), '')                           AS notes

FROM {{ ref('size_weight_rules_seed') }}
