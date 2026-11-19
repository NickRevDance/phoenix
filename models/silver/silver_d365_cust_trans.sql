{{ config(materialized = 'table') }}

-- Raw keeps SCD2 history; current version only. A row deleted in D365 has no current version, so a rebuild drops it.
SELECT
      ct.recid
    , ct.dataareaid
    , ct.accountnum
    , ct.orderaccount
    , ct.transdate
    , ct.transtype
    , ct.voucher
    , ct.invoice
    , ct.documentnum
    , ct.documentdate
    , ct.txt
    , ct.currencycode
    , ct.amountcur
    , ct.amountmst
    , ct.reportingcurrencyamount
    , ct.exchrate
    , ct.settleamountcur
    , ct.settleamountmst
    , ct.settleamountreporting
    , ct.custexchadjustmentrealized
    , ct.custexchadjustmentunrealized
    , ct.duedate
    , ct.closed
    , ct.lastsettledate
    , ct.lastsettlevoucher
    , ct.lastsettleaccountnum
    , ct.paymmode
    , ct.paymtermid
    , ct.paymreference
    , ct.paymid
    , ct.cashdisccode
    , ct.postingprofile
    , ct.prepayment
    , ct.cancelledpayment
    , ct.deliverymode
    , ct.mcrpaymorderid
    , ct.retailstoreid
    , ct.retailtransactionid
    , ct.defaultdimension
    , ct.createddatetime
    , ct.modifieddatetime
    , ct.SinkModifiedOn
FROM
    {{ ref('bronze_d365_synapse_cust_trans') }} ct
WHERE ct.__END_AT IS NULL
  AND ct.dataareaid <> 'dat'
