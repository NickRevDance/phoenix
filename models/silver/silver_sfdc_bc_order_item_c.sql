{{ config(materialized = 'table') }}

-- Line status, Shipped_Qty__c and Returned_Qty__c stopped being updated during 2021-2022; 'Open' means not maintained, not unshipped.
SELECT
      b.*
    , COALESCE(b.Status__c <> 'Open', false) AS is_status_maintained
FROM {{ ref('bronze_sfdc_bc_order_item_c') }} b
