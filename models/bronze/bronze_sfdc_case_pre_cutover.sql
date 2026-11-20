{{ config(materialized = 'view') }}

SELECT
    s.*
FROM
    {{ source('SFDC_history', 'sfdc_case_pre_cutover') }} s
