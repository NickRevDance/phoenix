SELECT

      TRIM(metric_code)                     AS metric_code
    , TRIM(metric_name)                     AS metric_name
    , TRIM(business_unit_code)              AS business_unit_code
    , TRIM(scope_type)                      AS scope_type
    , TRIM(scope_code)                      AS scope_code
    , TRIM(comparison_operator)             AS comparison_operator
    , CAST(target_value AS DECIMAL(18,4))   AS target_value
    , TRIM(target_unit)                     AS target_unit
    , TRIM(goal_direction)                  AS goal_direction
    , CAST(is_monitor_only_flag AS BOOLEAN) AS is_monitor_only_flag
    , CAST(effective_from_date AS DATE)     AS effective_from_date
    , CAST(effective_to_date AS DATE)       AS effective_to_date
    , NULLIF(TRIM(approved_by_role), '')    AS approved_by_role
    , CAST(approved_date AS DATE)           AS approved_date
    , NULLIF(TRIM(target_notes), '')        AS target_notes

FROM {{ ref('sla_target') }}
