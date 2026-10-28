{{ config(materialized = 'view') }}

SELECT
    gjae.*
FROM
    {{ source('byod', 'd365_general_journal_account_entry') }} gjae
