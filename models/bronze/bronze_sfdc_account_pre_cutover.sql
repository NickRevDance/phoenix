{{ config(materialized = 'view') }}

SELECT
    s.*
FROM
    {{ source('SFDC_history', 'sfdc_account_pre_cutover') }} s
