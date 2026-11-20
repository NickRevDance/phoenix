{{ config(materialized = 'table') }}

-- Marketing email events, source-agnostic. Today the only feed is Klaviyo's sync into Salesforce Tasks;
-- when Klaviyo lands natively, swap this model to the Klaviyo source (map profiles to accounts via Account.Klaviyo_ID__c).
SELECT
      t.Id AS marketing_email_event_id
    , 'Salesforce Klaviyo sync' AS event_source
    , t.klaviyo_event AS event_type
    , NULLIF(TRIM(REGEXP_EXTRACT(t.Subject, '^Klaviyo:\\s*\\w+\\s*\\S\\s*(.*)$', 1)), '') AS email_name
    , t.CreatedDate AS event_datetime
    , COALESCE(t.ActivityDate, CAST(FROM_UTC_TIMESTAMP(t.CreatedDate, 'America/Chicago') AS DATE)) AS event_date
    , t.AccountId AS sfdc_account_id
    , CASE WHEN t.who_object_type = 'Contact' THEN t.WhoId END AS sfdc_contact_id
FROM {{ ref('silver_sfdc_task') }} t
WHERE t.activity_channel = 'Marketing Email'
  AND t.IsDeleted = false
