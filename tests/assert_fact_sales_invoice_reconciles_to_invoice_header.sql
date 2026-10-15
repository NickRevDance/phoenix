-- Reconciliation rule 1 (FACT_SALES_INVOICE spec Section 7, F5 zero tolerance): per posted
-- CustInvoiceJour header, the sum of net_sales_amount over its lines equals SALESBALANCE.
-- Lines reach their header through CustInvoiceTrans.PARENTRECID = CustInvoiceJour.REC, the same
-- relation the fact uses. Over all rows, whatever is_intercompany_flag says, which is why that
-- flag is never a filter. Returns one row per header that does not tie, a header with lines in
-- the fact but no header row, or a header in silver with lines but none in the fact.
-- EDW-59 (from EDW-132): tied on 824,869 of 824,869 headers on Oct 15 2026.

with fact_header as (

    select

          t.PARENTRECID                          as header_rec_id
        , sum(f.net_sales_amount)                as net_sales_amount

    from {{ ref('fact_sales_invoice') }} f

    inner join {{ ref('silver_d365_cust_invoice_trans') }} t
        on t.RECID = f.d365_invoice_rec_id

    group by t.PARENTRECID

),

source_header as (

    select

          j.REC                                  as header_rec_id
        , j.INVOICEID                            as invoice_id
        , j.SALESBALANCE                         as salesbalance

    from {{ ref('silver_d365_cust_invoice_jour') }} j

    where j.REC in (select t.PARENTRECID from {{ ref('silver_d365_cust_invoice_trans') }} t)

)

select

      coalesce(s.header_rec_id, f.header_rec_id) as header_rec_id
    , s.invoice_id
    , s.salesbalance
    , f.net_sales_amount
    , case
        when s.header_rec_id is null then 'fact lines with no invoice header'
        when f.header_rec_id is null then 'invoice header with lines missing from the fact'
        else 'net_sales_amount does not equal SALESBALANCE'
      end                                        as failure

from source_header s

full outer join fact_header f
    on s.header_rec_id = f.header_rec_id

where s.header_rec_id is null
   or f.header_rec_id is null
   or f.net_sales_amount <> s.salesbalance