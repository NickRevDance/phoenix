{{ config(materialized = 'table') }}

WITH stage_map AS (
    SELECT
          s.stage_name
        , CAST(NULLIF(TRIM(s.stage_order), '') AS INT) AS stage_order
        , s.stage_outcome
    FROM {{ ref('sales_stage_map') }} s
    WHERE s.object_name = 'Opportunity'
),

stage_changes AS (
    SELECT
          h.OpportunityId
        , h.StageName
        , h.CreatedDate
        , h.Id
        , h.stage_order
        , h.stage_outcome
        , h.is_reopen
        , h.is_backward_move
        , ROW_NUMBER() OVER (PARTITION BY h.OpportunityId ORDER BY h.CreatedDate DESC, h.Id DESC) AS reverse_sequence
    FROM {{ ref('silver_sfdc_opportunity_history') }} h
    WHERE h.is_stage_change
),

stage_path AS (
    SELECT
          sc.OpportunityId
        , MIN_BY(sc.StageName, STRUCT(sc.CreatedDate, sc.Id)) AS entry_stage_name
        , MAX(CASE WHEN sc.stage_outcome = 'Open' THEN sc.stage_order END) AS highest_open_stage_order
        , COUNT(*) - 1 AS stage_change_count
        , MAX(CAST(sc.is_reopen AS INT)) = 1 AS is_reopened
        , MAX(CAST(sc.is_backward_move AS INT)) = 1 AS has_backward_move
        , MAX(CASE WHEN sc.reverse_sequence = 1 THEN sc.CreatedDate END) AS current_stage_entered_datetime
    FROM stage_changes sc
    GROUP BY sc.OpportunityId
),

lead_source AS (
    SELECT
          l.ConvertedOpportunityId
        , MIN(l.Id) AS converted_from_lead_id
    FROM {{ ref('bronze_sfdc_lead') }} l
    WHERE l.ConvertedOpportunityId IS NOT NULL
    GROUP BY l.ConvertedOpportunityId
)

SELECT
      b.*
    , rt.Name AS record_type_name
    , COALESCE(rt.Name, '') <> 'Sales Order' AS is_pipeline_opportunity
    , sm.stage_order
    , sm.stage_outcome
    , sp.entry_stage_name
    , CASE WHEN b.IsWon THEN sm.stage_order ELSE sp.highest_open_stage_order END AS highest_stage_order
    , hsm.stage_name AS highest_stage_name
    , COALESCE(sp.stage_change_count, 0) AS stage_change_count
    , COALESCE(esm.stage_outcome IN ('Won', 'Lost'), false) AS is_created_closed
    , COALESCE(sp.is_reopened, false) AS is_reopened
    , COALESCE(sp.has_backward_move, false) AS has_backward_move
    , sp.current_stage_entered_datetime
    , CASE WHEN b.IsClosed THEN sp.current_stage_entered_datetime END AS closed_datetime
    , ls.converted_from_lead_id
FROM {{ ref('bronze_sfdc_opportunity') }} b
LEFT JOIN {{ ref('silver_sfdc_record_type') }} rt
    ON rt.Id = b.RecordTypeId
LEFT JOIN stage_map sm
    ON sm.stage_name = b.StageName
LEFT JOIN stage_path sp
    ON sp.OpportunityId = b.Id
LEFT JOIN stage_map esm
    ON esm.stage_name = sp.entry_stage_name
LEFT JOIN stage_map hsm
    ON hsm.stage_order = CASE WHEN b.IsWon THEN sm.stage_order ELSE sp.highest_open_stage_order END
LEFT JOIN lead_source ls
    ON ls.ConvertedOpportunityId = b.Id
