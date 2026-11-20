{{ config(materialized = 'table') }}

SELECT
      b.*
    , {{ sfdc_object_type('b.WhatId') }} AS what_object_type
    , {{ sfdc_object_type('b.WhoId') }} AS who_object_type
    , 'Meeting' AS activity_channel
    , false AS is_automated
FROM {{ ref('bronze_sfdc_event') }} b
