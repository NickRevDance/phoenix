{{ config(materialized = 'view') }}

SELECT
    *
FROM
    {{ source('SFDC', 'sfdc_account') }}