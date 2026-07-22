{{ config(materialized = 'table') }}

SELECT
    *
FROM
    {{source("SFDC","sfdc_account")}}