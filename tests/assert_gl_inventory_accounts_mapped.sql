{{ config(severity = 'warn') }}

-- EDW-183 step 2 (Inventory spec 5.10): every D365 inventory main account (13xxxx) with an entry
-- on company REV has a row in REF_GL_INVENTORY_ACCOUNT, so the tie-out never misses an account.
-- A new account shows here until it is added to the gl_inventory_account seed.

select
      l.MAINACCOUNTID                       as main_account_id
    , count(*)                              as gl_lines
    , min(to_date(h.ACCOUNTINGDATE))        as first_accounting_date
    , max(to_date(h.ACCOUNTINGDATE))        as last_accounting_date
from {{ ref('silver_d365_general_journal_account_entry') }} l
inner join {{ ref('silver_d365_general_journal_entry') }} h
    on l.GENERALJOURNALENTRY = h.RECID
left anti join {{ ref('ref_gl_inventory_account') }} m
    on l.MAINACCOUNTID = m.main_account_id
where h.DATAAREAID = 'REV'
  and l.MAINACCOUNTID like '13%'
group by 1