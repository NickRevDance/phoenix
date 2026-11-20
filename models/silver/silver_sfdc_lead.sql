{{ config(materialized = 'table') }}

WITH status_map AS (
    SELECT
          s.stage_name
        , CAST(NULLIF(TRIM(s.stage_order), '') AS INT) AS stage_order
        , s.stage_outcome
    FROM {{ ref('sales_stage_map') }} s
    WHERE s.object_name = 'Lead'
),

account_first_order AS (
    SELECT
          o.AccountId
        , MIN(o.CloseDate) AS first_order_date
    FROM {{ ref('silver_sfdc_opportunity') }} o
    WHERE o.is_pipeline_opportunity = false
      AND o.IsWon = true
    GROUP BY o.AccountId
),

first_campaign AS (
    SELECT
          cm.LeadId
        , MIN_BY(cm.CampaignId, STRUCT(cm.CreatedDate, cm.Id)) AS first_campaign_id
    FROM {{ ref('bronze_sfdc_campaign_member') }} cm
    WHERE cm.LeadId IS NOT NULL
      AND cm.IsDeleted = false
    GROUP BY cm.LeadId
)

SELECT
      b.*
    , sm.stage_order AS status_order
    , CASE WHEN b.IsConverted THEN 'Converted' ELSE sm.stage_outcome END AS lead_outcome
    , CASE WHEN b.IsConverted
           THEN DATEDIFF(b.ConvertedDate, CAST(FROM_UTC_TIMESTAMP(b.CreatedDate, 'America/Chicago') AS DATE))
      END AS days_to_convert
    , afo.first_order_date AS converted_account_first_order_date
    , CASE WHEN b.IsConverted THEN COALESCE(afo.first_order_date < b.ConvertedDate, false) END AS is_existing_customer_at_conversion
    , fc.first_campaign_id
FROM {{ ref('bronze_sfdc_lead') }} b
LEFT JOIN status_map sm
    ON sm.stage_name = b.Status
LEFT JOIN account_first_order afo
    ON afo.AccountId = b.ConvertedAccountId
LEFT JOIN first_campaign fc
    ON fc.LeadId = b.Id
