{{ config(materialized = 'table') }}

SELECT
    b.*
FROM
    {{ ref('bronze_sfdc_email_message') }} b
