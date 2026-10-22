{{ config(materialized = 'table') }}

SELECT
    {{ generate_surrogate_key(['t.movement_reason_code']) }} AS movement_reason_key
    , t.movement_reason_code
    , t.reference_category_name
    , t.movement_reason_desc
    , t.default_movement_type
    , t.default_movement_subtype
    , t.is_included_flag
    , t.notes
    , 'Manual' AS source_system
    , 'movement_reason' AS record_source_table
    -- this key is used to identify the fields used in SCD2. If more fields need to be tracked they should be added to this list.
    , {{ generate_row_hash([
        "coalesce(t.reference_category_name, '')"
        , "coalesce(t.movement_reason_desc, '')"
        , "coalesce(t.default_movement_type, '')"
        , "coalesce(t.default_movement_subtype, '')"
        , "coalesce(cast(t.is_included_flag as string), '')"
    ]) }} AS movement_reason_change_hash

FROM (
    SELECT
        trim(s.movement_reason_code) AS movement_reason_code
        , trim(s.reference_category_name) AS reference_category_name
        , trim(s.movement_reason_desc) AS movement_reason_desc
        , trim(s.default_movement_type) AS default_movement_type
        , nullif(trim(s.default_movement_subtype), '') AS default_movement_subtype
        , cast(s.is_included_flag AS int) = 1 AS is_included_flag
        , nullif(trim(s.notes), '') AS notes
    FROM {{ ref('movement_reason') }} s
) t
