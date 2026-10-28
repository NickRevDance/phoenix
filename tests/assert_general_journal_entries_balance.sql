-- Every posted voucher's lines net to zero in accounting currency
SELECT
      gjae.GENERALJOURNALENTRY
    , SUM(gjae.ACCOUNTINGCURRENCYAMOUNT) AS net_accounting_amount
    , COUNT(*) AS line_count
FROM
    {{ ref('silver_d365_general_journal_account_entry') }} gjae
GROUP BY
    gjae.GENERALJOURNALENTRY
HAVING
    SUM(gjae.ACCOUNTINGCURRENCYAMOUNT) <> 0
