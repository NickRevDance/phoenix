{{ config(severity = 'warn') }}

-- EDW-183 step 2 (Inventory spec 5.10): V_INVENTORY_GL_TIE_OUT_MONTH_END leaves D365's July 1
-- opening vouchers out and sums the GL from inception, which holds only while each opening equals
-- the running sum of the entries before it. Checks that on every inventory account for every
-- year: returns each account and July 1 where the two differ by more than a cent. The opening is
-- the journal category 0 voucher in a fiscal period whose every voucher is dated July 1, the same
-- rule the view uses.

with opening_period as (

    select h.FISCALCALENDARPERIOD
    from {{ ref('silver_d365_general_journal_entry') }} h
    where h.DATAAREAID = 'REV'
    group by 1
    having min(to_date(h.ACCOUNTINGDATE)) = max(to_date(h.ACCOUNTINGDATE))
       and month(min(h.ACCOUNTINGDATE)) = 7
       and day(min(h.ACCOUNTINGDATE)) = 1

),

line as (

    select
          l.MAINACCOUNTID as main_account_id
        , to_date(h.ACCOUNTINGDATE) as accounting_date
        , op.FISCALCALENDARPERIOD is not null as is_opening
        , cast(l.ACCOUNTINGCURRENCYAMOUNT as decimal(38, 6)) as amount
    from {{ ref('silver_d365_general_journal_account_entry') }} l
    inner join {{ ref('silver_d365_general_journal_entry') }} h
        on l.GENERALJOURNALENTRY = h.RECID
    inner join {{ ref('ref_gl_inventory_account') }} m
        on l.MAINACCOUNTID = m.main_account_id
    left join opening_period op
        on h.FISCALCALENDARPERIOD = op.FISCALCALENDARPERIOD
       and h.JOURNALCATEGORY = 0
    where h.DATAAREAID = 'REV'

),

opening as (

    select main_account_id, accounting_date as opening_date, sum(amount) as opening_amount
    from line
    where is_opening
    group by 1, 2

),

daily as (

    select main_account_id, accounting_date, sum(amount) as amount
    from line
    where not is_opening
    group by 1, 2

),

carried as (

    select
          o.main_account_id
        , o.opening_date
        , o.opening_amount
        , coalesce(sum(d.amount), 0) as running_sum_before
    from opening o
    left join daily d
        on d.main_account_id = o.main_account_id
       and d.accounting_date < o.opening_date
    group by 1, 2, 3

)

select
      main_account_id
    , opening_date
    , opening_amount
    , running_sum_before
    , opening_amount - running_sum_before as difference
from carried
where abs(opening_amount - running_sum_before) > 0.01