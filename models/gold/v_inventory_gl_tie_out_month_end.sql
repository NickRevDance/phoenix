{{ config(materialized = 'view') }}

{% set gl_company = 'REV' %}           {# the only legal entity with inventory: RUB and RDL post no 13xxxx lines #}
{% set tie_tolerance = 10000 %}        {# USD per bucket and on the total, ratified 2026-10-29 #}
{% set in_transit_location_type = '10' %}  {# D365 InventLocationType 10 = goods in transit; 2 (transfer transit, -T) posts to on hand #}

-- V_INVENTORY_GL_TIE_OUT_MONTH_END (Inventory spec v2.15, Section 5.10; EDW-183 step 2, decision
-- record I6 point 9). One row per month-end close and GL bucket, plus a TOTAL_TIED row (on hand
-- plus goods in transit), from June 2024. It sets the general ledger balance on the D365
-- inventory main accounts beside D365's own Inventory value report and gold's value at the same
-- close, with the reconciling lines between them.
-- CLOSES: the close rows of V_INVENTORY_VALUE_MONTH_END (I6 point 6), so the tie reads the same
-- closes as the report.
-- GL BALANCE: every non-opening entry dated on or before the month-end, company {{ gl_company }}. D365's
-- year-end close posts one opening voucher each July 1 (journal category 0, in its own single-date
-- fiscal period) that carries the prior balance forward; it equals the running sum of the entries
-- before it to the cent on every inventory account, 2021 to 2026, so it is left out and the
-- balance is summed from inception. assert_gl_inventory_opening_balances_carry_forward re-checks
-- that each year.
-- BUCKETS: REF_GL_INVENTORY_ACCOUNT. ON_HAND (130020) and IN_TRANSIT (130070) receive D365's
-- inventory subledger postings and are compared with D365 and gold, split by the warehouse's D365
-- location type: type {{ in_transit_location_type }} (the -GT warehouses and DropShip-G) is in transit, everything else
-- (transfer transit -T included, which D365 posts to 130020) is on hand. The other buckets are GL
-- only and carry no D365 or gold value.
-- D365: D365's Inventory value report at the close date (silver_kpi_inventory_value, the
-- subledger valuation gold's history was filled from). Closes through January 2026 come from
-- D365's re-runs of 2026-02-11 as of each month-end, so they include entries created after the
-- month-end; from February 2026 the daily run executes at about 00:01 Central on the 1st.
-- GOLD: moving_avg_cost_amount on every snapshot row at the close date, all statuses (the ledger
-- carries every status), with the certified report scope beside it from
-- V_INVENTORY_VALUE_MONTH_END.
-- RECONCILING LINES:
--   gl_manual_journal_in_month_amount: manual journal lines (posting type 14) dated in the
--     month. Accounting's top-side entries, which the subledger never sees (Dec 2024: an
--     overstated vendor invoice corrected by a journal dated Dec 31, reversed Jan 1).
--   gl_posted_after_close_amount: entries dated on or before the month-end but created after
--     midnight Central at its end, when D365's daily run executes. Only on closes read from the
--     1st of the next month (from February 2026); NULL on earlier closes, whose D365 re-runs
--     already include them. CREATEDDATE is UTC and is read in Central time.
-- STATUS (tolerance {{ tie_tolerance }} USD): TIES when gold is within tolerance of the GL balance; else
-- TIES_EXCL_MANUAL_JOURNALS when it is once the month's manual journals are set aside; else
-- TIES_AT_CLOSE when it is once entries posted after the close are set aside; else LATE_CAPTURE
-- when the close is a flagged afternoon capture and D365's run ties the GL at the close; else
-- VARIANCE. GL_ONLY on the buckets not compared. assert_v_inventory_gl_tie_out_month_end_ties
-- reports every VARIANCE row.
-- Amounts sum in decimal: the subledger carries a few offsetting lines of about 1e13 USD (D365
-- costing errors on 2024-12-26 to 31 and 2025-06-13) that net out within days.

with account_map as (

    select
          main_account_id
        , gl_bucket
        , gl_bucket_description
        , is_tied_to_gold_flag
        , bucket_sort_order
    from {{ ref('ref_gl_inventory_account') }}

),

bucket as (

    select
          gl_bucket
        , max(gl_bucket_description)                                  as gl_bucket_description
        , bool_or(is_tied_to_gold_flag)                               as is_tied_to_gold_flag
        , min(bucket_sort_order)                                      as bucket_sort_order
        , array_join(array_sort(collect_list(main_account_id)), ', ') as main_account_ids
    from account_map
    group by 1

),

closes as (

    select distinct
          month_end_date_key
        , month_end_date
        , close_snapshot_date
        , close_rule
        , is_close_captured_late_flag
    from {{ ref('v_inventory_value_month_end') }}

),

opening_period as (

    -- D365's year-end opening: a fiscal period whose every voucher is dated July 1
    select h.FISCALCALENDARPERIOD
    from {{ ref('silver_d365_general_journal_entry') }} h
    where h.DATAAREAID = '{{ gl_company }}'
    group by 1
    having min(to_date(h.ACCOUNTINGDATE)) = max(to_date(h.ACCOUNTINGDATE))
       and month(min(h.ACCOUNTINGDATE)) = 7
       and day(min(h.ACCOUNTINGDATE)) = 1

),

gl_line as (

    select
          m.gl_bucket
        , to_date(h.ACCOUNTINGDATE)                                   as accounting_date
        , from_utc_timestamp(h.CREATEDDATE, 'America/Chicago')        as created_datetime_ct
        , coalesce(l.POSTINGTYPE = 14, false)                         as is_manual_journal
        , cast(l.ACCOUNTINGCURRENCYAMOUNT as decimal(38, 6))          as amount
    from {{ ref('silver_d365_general_journal_account_entry') }} l
    inner join {{ ref('silver_d365_general_journal_entry') }} h
        on l.GENERALJOURNALENTRY = h.RECID
    inner join account_map m
        on l.MAINACCOUNTID = m.main_account_id
    left join opening_period op
        on h.FISCALCALENDARPERIOD = op.FISCALCALENDARPERIOD
       and h.JOURNALCATEGORY = 0
    where h.DATAAREAID = '{{ gl_company }}'
      and op.FISCALCALENDARPERIOD is null  -- opening vouchers out

),

gl_daily as (

    select
          gl_bucket
        , accounting_date
        , sum(amount) as amount
    from gl_line
    group by 1, 2

),

gl_close as (

    select
          c.month_end_date
        , d.gl_bucket
        , sum(d.amount) as gl_balance_amount
    from closes c
    inner join gl_daily d
        on d.accounting_date <= c.month_end_date
    group by 1, 2

),

gl_manual as (

    select
          c.month_end_date
        , g.gl_bucket
        , sum(g.amount) as gl_manual_journal_in_month_amount
    from closes c
    inner join gl_line g
        on g.is_manual_journal
       and g.accounting_date >= trunc(c.month_end_date, 'MM')
       and g.accounting_date <= c.month_end_date
    group by 1, 2

),

gl_late as (

    select
          c.month_end_date
        , g.gl_bucket
        , sum(g.amount) as gl_posted_after_close_amount
    from closes c
    inner join gl_line g
        on c.close_rule = 'NEXT_MONTH_FIRST_ROW'
       and g.accounting_date <= c.month_end_date
       and g.created_datetime_ct >= cast(c.close_snapshot_date as timestamp)
    group by 1, 2

),

warehouse_bucket as (

    select distinct
          warehouse_id
        , case when d365_location_type = '{{ in_transit_location_type }}' then 'IN_TRANSIT' else 'ON_HAND' end as gl_bucket
    from {{ ref('dim_warehouse') }}
    where version_number = 1

),

d365_close as (

    select
          c.month_end_date
        , coalesce(w.gl_bucket, 'ON_HAND') as gl_bucket
        , sum(cast(k.InventoryAmount as decimal(38, 6))) as d365_value_amount
    from closes c
    inner join {{ ref('silver_kpi_inventory_value') }} k
        on k.SnapshotDate = c.close_snapshot_date
    left join warehouse_bucket w
        on k.WarehouseId = w.warehouse_id
    group by 1, 2

),

gold_close as (

    select
          c.month_end_date
        , coalesce(w.gl_bucket, 'ON_HAND') as gl_bucket
        , sum(f.moving_avg_cost_amount) as gold_value_amount
    from closes c
    inner join {{ ref('fact_inventory_snapshot_daily') }} f
        on f.snapshot_date = c.close_snapshot_date
    left join warehouse_bucket w
        on f.warehouse_id = w.warehouse_id
    group by 1, 2

),

scope_close as (

    select
          v.month_end_date
        , coalesce(w.gl_bucket, 'ON_HAND') as gl_bucket
        , sum(v.moving_avg_cost_amount) as gold_report_scope_amount
    from {{ ref('v_inventory_value_month_end') }} v
    left join warehouse_bucket w
        on v.warehouse_id = w.warehouse_id
    group by 1, 2

),

by_bucket as (

    select
          c.month_end_date_key
        , c.month_end_date
        , c.close_snapshot_date
        , c.close_rule
        , c.is_close_captured_late_flag
        , b.gl_bucket
        , b.gl_bucket_description
        , b.main_account_ids
        , b.is_tied_to_gold_flag
        , b.bucket_sort_order
        , coalesce(gc.gl_balance_amount, 0)                                                 as gl_balance_amount
        , coalesce(gm.gl_manual_journal_in_month_amount, 0)                                 as gl_manual_journal_in_month_amount
        , case when c.close_rule = 'NEXT_MONTH_FIRST_ROW'
               then coalesce(lt.gl_posted_after_close_amount, 0) end                        as gl_posted_after_close_amount
        , case when b.is_tied_to_gold_flag then coalesce(dc.d365_value_amount, 0) end       as d365_value_amount
        , case when b.is_tied_to_gold_flag then coalesce(gd.gold_value_amount, 0) end       as gold_value_amount
        , case when b.is_tied_to_gold_flag then coalesce(sc.gold_report_scope_amount, 0) end as gold_report_scope_amount
    from closes c
    cross join bucket b
    left join gl_close gc
        on c.month_end_date = gc.month_end_date and b.gl_bucket = gc.gl_bucket
    left join gl_manual gm
        on c.month_end_date = gm.month_end_date and b.gl_bucket = gm.gl_bucket
    left join gl_late lt
        on c.month_end_date = lt.month_end_date and b.gl_bucket = lt.gl_bucket
    left join d365_close dc
        on c.month_end_date = dc.month_end_date and b.gl_bucket = dc.gl_bucket
    left join gold_close gd
        on c.month_end_date = gd.month_end_date and b.gl_bucket = gd.gl_bucket
    left join scope_close sc
        on c.month_end_date = sc.month_end_date and b.gl_bucket = sc.gl_bucket

),

total_tied as (

    select
          month_end_date_key
        , month_end_date
        , close_snapshot_date
        , close_rule
        , is_close_captured_late_flag
        , 'TOTAL_TIED'                         as gl_bucket
        , 'On hand plus goods in transit'      as gl_bucket_description
        , array_join(array_sort(collect_list(main_account_ids)), ', ') as main_account_ids
        , true                                 as is_tied_to_gold_flag
        , 99                                   as bucket_sort_order
        , sum(gl_balance_amount)               as gl_balance_amount
        , sum(gl_manual_journal_in_month_amount) as gl_manual_journal_in_month_amount
        , sum(gl_posted_after_close_amount)    as gl_posted_after_close_amount
        , sum(d365_value_amount)               as d365_value_amount
        , sum(gold_value_amount)               as gold_value_amount
        , sum(gold_report_scope_amount)        as gold_report_scope_amount
    from by_bucket
    where is_tied_to_gold_flag
    group by 1, 2, 3, 4, 5

),

unioned as (

    select * from by_bucket
    union all
    select * from total_tied

),

final as (

    select

    -- Close
          u.month_end_date_key  -- relate to DIM_DATE here
        , u.month_end_date
        , u.close_snapshot_date
        , u.close_rule
        , u.is_close_captured_late_flag

    -- Bucket
        , u.gl_bucket
        , u.gl_bucket_description
        , u.main_account_ids
        , u.is_tied_to_gold_flag
        , u.bucket_sort_order

    -- GL
        , cast(u.gl_balance_amount as decimal(19, 2))                                       as gl_balance_amount
        , cast(u.gl_manual_journal_in_month_amount as decimal(19, 2))                       as gl_manual_journal_in_month_amount
        , cast(u.gl_posted_after_close_amount as decimal(19, 2))                            as gl_posted_after_close_amount
        , cast(u.gl_balance_amount - coalesce(u.gl_posted_after_close_amount, 0) as decimal(19, 2)) as gl_balance_at_close_amount

    -- D365 and gold
        , cast(u.d365_value_amount as decimal(19, 2))                                       as d365_value_amount
        , cast(u.gold_value_amount as decimal(19, 2))                                       as gold_value_amount
        , cast(u.gold_report_scope_amount as decimal(19, 2))                                as gold_report_scope_amount

    -- Variances
        , cast(u.gold_value_amount - u.gl_balance_amount as decimal(19, 2))                 as variance_gold_to_gl_amount
        , cast(u.d365_value_amount - (u.gl_balance_amount - coalesce(u.gl_posted_after_close_amount, 0)) as decimal(19, 2)) as variance_d365_to_gl_at_close_amount
        , cast({{ tie_tolerance }} as decimal(19, 2))                                       as tie_tolerance_amount
        , case
            when not u.is_tied_to_gold_flag then 'GL_ONLY'
            when abs(u.gold_value_amount - u.gl_balance_amount) <= {{ tie_tolerance }} then 'TIES'
            when abs(u.gold_value_amount - (u.gl_balance_amount - u.gl_manual_journal_in_month_amount)) <= {{ tie_tolerance }} then 'TIES_EXCL_MANUAL_JOURNALS'
            when u.gl_posted_after_close_amount is not null
             and abs(u.gold_value_amount - (u.gl_balance_amount - u.gl_posted_after_close_amount)) <= {{ tie_tolerance }} then 'TIES_AT_CLOSE'
            when u.is_close_captured_late_flag = 1
             and abs(u.d365_value_amount - (u.gl_balance_amount - coalesce(u.gl_posted_after_close_amount, 0))) <= {{ tie_tolerance }} then 'LATE_CAPTURE'
            else 'VARIANCE'
          end                                                                               as tie_status

    from unioned u

)

select * from final