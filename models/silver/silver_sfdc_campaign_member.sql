{{ config(materialized = 'table') }}

SELECT
      b.*
    , COALESCE(c.AccountId, l.ConvertedAccountId, b.AccountId) AS member_account_id
FROM {{ ref('bronze_sfdc_campaign_member') }} b
LEFT JOIN {{ ref('bronze_sfdc_contact') }} c
    ON c.Id = b.ContactId
LEFT JOIN {{ ref('bronze_sfdc_lead') }} l
    ON l.Id = b.LeadId
