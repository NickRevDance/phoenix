{{ config(materialized = 'table') }}

WITH stage_map AS (
    SELECT
          s.stage_name
        , CAST(NULLIF(TRIM(s.stage_order), '') AS INT) AS stage_order
        , s.stage_outcome
    FROM {{ ref('sales_stage_map') }} s
    WHERE s.object_name = 'Opportunity'
),

history AS (
    SELECT
          b.*
        , sm.stage_order
        , sm.stage_outcome
        , ROW_NUMBER() OVER (PARTITION BY b.OpportunityId ORDER BY b.CreatedDate, b.Id) AS history_sequence_number
        , LAG(b.StageName) OVER (PARTITION BY b.OpportunityId ORDER BY b.CreatedDate, b.Id) AS prior_stage_name
    FROM {{ ref('bronze_sfdc_opportunity_history') }} b
    LEFT JOIN stage_map sm
        ON sm.stage_name = b.StageName
    WHERE b.IsDeleted = false
)

SELECT
      h.*
    , psm.stage_order AS prior_stage_order
    , psm.stage_outcome AS prior_stage_outcome
    , h.prior_stage_name IS NULL OR h.prior_stage_name <> h.StageName AS is_stage_change
    , psm.stage_outcome IN ('Won', 'Lost') AND h.stage_outcome = 'Open' AS is_reopen
    , h.stage_order < psm.stage_order AS is_backward_move
FROM history h
LEFT JOIN stage_map psm
    ON psm.stage_name = h.prior_stage_name
