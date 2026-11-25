{{ config(materialized = 'table') }}

-- Status__c stops being maintained after sync: 'Awaiting Fulfillment' is the sync default, not a fulfillment state.
SELECT
      b.*
    , COALESCE(b.Status__c NOT IN ('Awaiting Fulfillment'), false) AS is_status_maintained
FROM {{ ref('bronze_sfdc_bc_order_c') }} b
