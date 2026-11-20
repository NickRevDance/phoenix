{{ config(materialized = 'view') }}

SELECT
    s.*
FROM
    {{ source('SFDC', 'sfdc_opportunity_history') }} s
