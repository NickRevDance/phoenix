{{ config(materialized = 'view') }}

SELECT
    gje.*
FROM
    {{ source('byod', 'd365_general_journal_entry') }} gje
