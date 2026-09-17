SELECT

      TRIM(setting_name)                       AS setting_name
    , TRIM(scope_product_subgroup)               AS scope_product_subgroup
    , CAST(setting_value AS DECIMAL(18,6))        AS setting_value
    , TRIM(setting_type)                         AS setting_type
    , CAST(is_active AS INT)                     AS is_active
    , CAST(effective_start_date AS DATE)          AS effective_start_date
    , CAST(effective_end_date AS DATE)            AS effective_end_date
    , NULLIF(TRIM(notes), '')                    AS notes

FROM {{ ref('inventory_quality_thresholds_seed') }}
