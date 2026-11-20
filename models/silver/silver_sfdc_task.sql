{{ config(materialized = 'table') }}

SELECT
      b.*
    , {{ sfdc_object_type('b.WhatId') }} AS what_object_type
    , {{ sfdc_object_type('b.WhoId') }} AS who_object_type
    , CASE
        WHEN b.Subject LIKE 'Klaviyo:%' THEN 'Marketing Email'
        WHEN b.TaskSubtype = 'Call' THEN 'Call'
        WHEN b.TaskSubtype IN ('Email', 'ListEmail') OR b.Type = 'Email' THEN 'Email'
        ELSE 'Task'
      END AS activity_channel
    , b.Subject LIKE 'Klaviyo:%'
      OR b.Subject LIKE 'Order Status Email%'
      OR (u.user_category = 'Integration' AND COALESCE(b.TaskSubtype, '') <> 'Call') AS is_automated
    , CASE WHEN b.Subject LIKE 'Klaviyo:%' THEN REGEXP_EXTRACT(b.Subject, '^Klaviyo:\\s*(\\w+)', 1) END AS klaviyo_event
FROM {{ ref('bronze_sfdc_task') }} b
LEFT JOIN {{ ref('silver_sfdc_user') }} u
    ON u.Id = b.OwnerId
