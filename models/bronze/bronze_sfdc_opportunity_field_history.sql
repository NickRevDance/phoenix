{{ config(materialized = 'view') }}

SELECT
    s.*
FROM
    {{ source('SFDC', 'sfdc_opportunity_field_history') }} s
