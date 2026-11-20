{{ config(materialized = 'table') }}

SELECT
    b.*
FROM
    {{ ref('bronze_sfdc_queue_s_object') }} b
