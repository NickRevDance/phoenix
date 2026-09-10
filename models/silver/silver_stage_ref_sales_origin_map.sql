SELECT

      TRIM(sales_origin_id)                AS sales_origin_id
    , NULLIF(TRIM(origin_description), '')  AS origin_description
    , TRIM(channel_code)                    AS channel_code
    , TRIM(mapping_confidence)              AS mapping_confidence
    , TRIM(source_system)                   AS source_system
    , CAST(is_active_flag AS INT)           AS is_active_flag
    , NULLIF(TRIM(mapping_notes), '')       AS mapping_notes

FROM {{ ref('sales_origin_map') }}
