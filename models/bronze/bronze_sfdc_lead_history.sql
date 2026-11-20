{{ config(materialized = 'view') }}

SELECT
    s.*
FROM
    {{ source('SFDC', 'sfdc_lead_history') }} s
