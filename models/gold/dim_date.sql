{{ config(materialized='table') }}

-- =============================================================================
-- DIM_DATE - Gold Layer conformed date dimension
-- Revolution Dancewear - AI/BI Data Gold Layer
-- Implements: DIM_DATE Gold Layer Specification v2.0 (Sections 3, 7, 8)
-- Grain: one row per calendar date, 2005-01-01 through 2036-12-31 (11,688 rows)
--
-- Day-of-week fields use deterministic anchor-date arithmetic instead of
-- dialect week functions, per spec Section 7.2 ("must NOT rely on default
-- SQL Server or Databricks week functions"):
--   2005-01-02 was a Sunday; 2005-01-03 was a Monday.
-- =============================================================================

with date_spine as (

    select explode(sequence(to_date('2005-01-01'), to_date('2036-12-31'), interval 1 day)) as date

),

base as (

    select
        date,
        year(date)                                                        as calendar_year,
        month(date)                                                       as month_number,
        day(date)                                                         as day_of_month,
        dayofyear(date)                                                   as day_of_year,
        quarter(date)                                                     as quarter_number,
        -- Sun=1 .. Sat=7 (anchor 2005-01-02 = Sunday)
        ((datediff(day, to_date('2005-01-02'), date) % 7) + 7) % 7 + 1    as day_of_week,
        -- Mon=1 .. Sun=7 (anchor 2005-01-03 = Monday)
        ((datediff(day, to_date('2005-01-03'), date) % 7) + 7) % 7 + 1    as day_of_week_monday
    from date_spine

),

calendar_attrs as (

    select
        b.*,
        cast(date_format(b.date, 'yyyyMMdd') as int)                      as date_key,
        date_format(b.date, 'EEEE')                                       as week_day_name,
        case
            when b.day_of_month in (1, 21, 31) then 'st'
            when b.day_of_month in (2, 22)     then 'nd'
            when b.day_of_month in (3, 23)     then 'rd'
            else 'th'
        end                                                               as day_suffix,
        floor((b.day_of_month - 1) / 7) + 1                               as dow_in_month,
        b.day_of_week in (1, 7)                                           as is_weekend,
        -- Non-retail week numbering: deterministic day-block arithmetic (spec 7.2)
        floor((b.day_of_month - 1) / 7) + 1                               as week_of_month,
        floor((b.day_of_year - 1) / 7) + 1                                as week_of_year,
        weekofyear(b.date)                                                as iso_week_of_year,
        date_format(b.date, 'MMMM')                                       as month_name,
        date_format(b.date, 'MMM-yyyy')                                   as month_year_short,
        date_format(b.date, 'MMMM yyyy')                                  as month_year_long,
        b.calendar_year * 100 + b.month_number                            as year_month_int,
        date_format(b.date, 'MMyyyy')                                     as mmyyyy,
        concat('Q', b.quarter_number)                                     as quarter_name,
        trunc(b.date, 'MM')                                               as first_day_of_month,
        last_day(b.date)                                                  as last_day_of_month,
        trunc(b.date, 'QUARTER')                                          as first_day_of_quarter,
        dateadd(day, -1, add_months(trunc(b.date, 'QUARTER'), 3))         as last_day_of_quarter,
        make_date(b.calendar_year, 1, 1)                                  as first_day_of_year,
        make_date(b.calendar_year, 12, 31)                                as last_day_of_year,
        add_months(trunc(b.date, 'MM'), 1)                                as first_day_of_next_month,
        make_date(b.calendar_year + 1, 1, 1)                              as first_day_of_next_year
    from base b

),

fiscal as (

    select
        c.*,
        case when c.month_number >= 7 then c.calendar_year + 1 else c.calendar_year end   as fiscal_year,
        case when c.month_number >= 7 then c.month_number - 6 else c.month_number + 6 end as fiscal_month
    from calendar_attrs c

),

fiscal_attrs as (

    select
        f.*,
        cast(ceil(f.fiscal_month / 3.0) as int)                           as fiscal_quarter,
        concat('FQ', cast(ceil(f.fiscal_month / 3.0) as int))             as fiscal_quarter_name,
        concat('FM', lpad(cast(f.fiscal_month as string), 2, '0'),
               ' - ', date_format(f.date, 'MMM'))                         as fiscal_month_name,
        datediff(day, make_date(f.fiscal_year - 1, 7, 1), f.date) + 1     as fiscal_year_day,
        f.fiscal_year * 100 + f.fiscal_month                              as fiscal_year_month_int,
        concat('FY', cast(f.fiscal_year as string),
               ' FM', lpad(cast(f.fiscal_month as string), 2, '0'))       as fiscal_year_month_label
    from fiscal f

),

fiscal_week as (

    select
        fa.*,
        floor((fa.fiscal_year_day - 1) / 7) + 1                           as fiscal_year_week
    from fiscal_attrs fa

),

-- Retail year membership comes from the authoritative seed (spec 7.3):
-- dbt does not compute year boundaries.
retail_join as (

    select
        fw.*,
        r.retail_year,
        r.retail_year_start_date,
        r.retail_year_end_date,
        r.weeks_in_retail_year                                            as retail_weeks_in_year,
        datediff(day, r.retail_year_start_date, fw.date) + 1              as retail_day_of_year
    from fiscal_week fw
    inner join {{ ref('retail_calendar_years') }} r
        on fw.date between r.retail_year_start_date and r.retail_year_end_date

),

retail_base as (

    select
        rj.*,
        cast(floor((rj.retail_day_of_year - 1) / 7) + 1 as int)           as retail_week,
        cast(((rj.retail_day_of_year - 1) % 7) + 1 as int)                as retail_day_of_week
    from retail_join rj

),

retail_period_calc as (

    select
        rb.*,
        -- Cumulative 4-5-4 week boundaries: 4,9,13,17,22,26,30,35,39,43,48,52.
        -- Week 53 falls through to period 12 (spec 2.4 / 7.3).
        case
            when rb.retail_week <= 4  then 1
            when rb.retail_week <= 9  then 2
            when rb.retail_week <= 13 then 3
            when rb.retail_week <= 17 then 4
            when rb.retail_week <= 22 then 5
            when rb.retail_week <= 26 then 6
            when rb.retail_week <= 30 then 7
            when rb.retail_week <= 35 then 8
            when rb.retail_week <= 39 then 9
            when rb.retail_week <= 43 then 10
            when rb.retail_week <= 48 then 11
            else 12
        end                                                               as retail_period
    from retail_base rb

),

retail_attrs as (

    select
        rp.*,
        cast(ceil(rp.retail_period / 3.0) as int)                         as retail_quarter,
        concat('RQ', cast(ceil(rp.retail_period / 3.0) as int))           as retail_quarter_name,
        concat('P', lpad(cast(rp.retail_period as string), 2, '0'))       as retail_period_name,
        -- First week of each period: 1,5,10,14,18,23,27,31,36,40,44,49
        case rp.retail_period
            when 1  then 1  when 2  then 5  when 3  then 10
            when 4  then 14 when 5  then 18 when 6  then 23
            when 7  then 27 when 8  then 31 when 9  then 36
            when 10 then 40 when 11 then 44 else 49
        end                                                               as retail_period_start_week,
        -- Last week of each period; P12 absorbs week 53 (spec 2.4)
        case rp.retail_period
            when 1  then 4  when 2  then 9  when 3  then 13
            when 4  then 17 when 5  then 22 when 6  then 26
            when 7  then 30 when 8  then 35 when 9  then 39
            when 10 then 43 when 11 then 48 else rp.retail_weeks_in_year
        end                                                               as retail_period_end_week,
        case rp.retail_period
            when 1 then 1 when 2 then 1 when 3 then 1
            when 4 then 14 when 5 then 14 when 6 then 14
            when 7 then 27 when 8 then 27 when 9 then 27
            else 40
        end                                                               as retail_quarter_start_week,
        case
            when rp.retail_period <= 3 then 13
            when rp.retail_period <= 6 then 26
            when rp.retail_period <= 9 then 39
            else rp.retail_weeks_in_year
        end                                                               as retail_quarter_end_week
    from retail_period_calc rp

),

retail_final as (

    select
        ra.*,
        ra.retail_week - ra.retail_period_start_week + 1                  as retail_week_in_period,
        ra.retail_weeks_in_year = 53                                      as is_53_week_retail_year,
        ra.retail_week = 53                                               as is_retail_week_53,
        dateadd(day, (ra.retail_week - 1) * 7, ra.retail_year_start_date) as retail_week_start_date,
        dateadd(day, (ra.retail_week - 1) * 7 + 6, ra.retail_year_start_date)
                                                                          as retail_week_end_date,
        dateadd(day, (ra.retail_period_start_week - 1) * 7, ra.retail_year_start_date)
                                                                          as retail_period_start_date,
        dateadd(day, ra.retail_period_end_week * 7 - 1, ra.retail_year_start_date)
                                                                          as retail_period_end_date,
        dateadd(day, (ra.retail_quarter_start_week - 1) * 7, ra.retail_year_start_date)
                                                                          as retail_quarter_start_date,
        dateadd(day, ra.retail_quarter_end_week * 7 - 1, ra.retail_year_start_date)
                                                                          as retail_quarter_end_date,
        ra.retail_year * 100 + ra.retail_period                           as retail_year_period_int,
        ra.retail_year * 100 + ra.retail_week                             as retail_year_week_int,
        concat('RY', cast(ra.retail_year as string),
               ' P', lpad(cast(ra.retail_period as string), 2, '0'))      as retail_year_period_label,
        -- Comparable dates: NRF restated methodology (spec 2.5 / 7.3).
        -- Fixed offsets preserve weekday and implement the restatement shift.
        -- Week 53 is an extra, non-comparable week -> NULL.
        -- Results before 2005-01-01 -> NULL.
        case when ra.retail_week = 53 then null
             when dateadd(day, -364,  ra.date) <  to_date('2005-01-01') then null
             else dateadd(day, -364,  ra.date) end                        as comparable_date_ly,
        case when ra.retail_week = 53 then null
             when dateadd(day, -728,  ra.date) <  to_date('2005-01-01') then null
             else dateadd(day, -728,  ra.date) end                        as comparable_date_2ly,
        case when ra.retail_week = 53 then null
             when dateadd(day, -1092, ra.date) <  to_date('2005-01-01') then null
             else dateadd(day, -1092, ra.date) end                        as comparable_date_3ly
    from retail_attrs ra

),

with_holidays as (

    select
        rf.*,
        coalesce(h.is_us_holiday, false)                                  as is_us_holiday,
        h.us_holiday_name,
        coalesce(h.is_canada_holiday, false)                              as is_canada_holiday,
        h.canada_holiday_name,
        -- Spec 7.4: only Company-observed holidays affect working days
        rf.day_of_week_monday <= 5
            and coalesce(h.is_company_working_day, true)                  as is_working_day
    from retail_final rf
    left join {{ ref('stg_holiday_calendar') }} h
        on rf.date = h.date

),

with_pacing as (

    select
        wh.*,
        -- Pacing - FY (calendar days)
        count(*)      over (partition by wh.fiscal_year)                  as fiscal_year_total_days,
        count(*)      over (partition by wh.fiscal_year order by wh.date) as fiscal_days_elapsed,
        -- Pacing - FM
        count(*)      over (partition by wh.fiscal_year, wh.fiscal_month) as fiscal_month_total_days,
        count(*)      over (partition by wh.fiscal_year, wh.fiscal_month order by wh.date)
                                                                          as fiscal_month_days_elapsed,
        -- Pacing - FQ
        count(*)      over (partition by wh.fiscal_year, wh.fiscal_quarter)
                                                                          as fiscal_quarter_total_days,
        count(*)      over (partition by wh.fiscal_year, wh.fiscal_quarter order by wh.date)
                                                                          as fiscal_quarter_days_elapsed,
        -- Pacing - WD (working days)
        sum(case when wh.is_working_day then 1 else 0 end)
                      over (partition by wh.fiscal_year)                  as working_days_in_fiscal_year,
        sum(case when wh.is_working_day then 1 else 0 end)
                      over (partition by wh.fiscal_year order by wh.date) as working_days_elapsed_fy,
        sum(case when wh.is_working_day then 1 else 0 end)
                      over (partition by wh.fiscal_year, wh.fiscal_month) as working_days_in_fiscal_month,
        sum(case when wh.is_working_day then 1 else 0 end)
                      over (partition by wh.fiscal_year, wh.fiscal_month order by wh.date)
                                                                          as working_days_elapsed_fm
    from with_holidays wh

)

select
    -- Keys
    date_key,
    date,
    -- Calendar core
    day_of_month,
    day_suffix,
    day_of_year,
    day_of_week,
    week_day_name,
    day_of_week_monday,
    dow_in_month,
    is_weekend,
    -- Holidays
    is_us_holiday,
    us_holiday_name,
    is_canada_holiday,
    canada_holiday_name,
    is_working_day,
    -- Weeks
    week_of_month,
    week_of_year,
    iso_week_of_year,
    -- Calendar month / quarter / year
    month_number,
    month_name,
    month_year_short,
    month_year_long,
    year_month_int,
    mmyyyy,
    quarter_number,
    quarter_name,
    calendar_year,
    -- Calendar boundaries
    first_day_of_month,
    last_day_of_month,
    first_day_of_quarter,
    last_day_of_quarter,
    first_day_of_year,
    last_day_of_year,
    first_day_of_next_month,
    first_day_of_next_year,
    -- Fiscal
    fiscal_year,
    fiscal_quarter,
    fiscal_quarter_name,
    fiscal_month,
    fiscal_month_name,
    fiscal_year_week,
    fiscal_year_day,
    fiscal_year_month_int,
    fiscal_year_month_label,
    -- Retail 4-5-4
    retail_year,
    retail_quarter,
    retail_quarter_name,
    retail_period,
    retail_period_name,
    retail_week,
    retail_week_in_period,
    retail_day_of_week,
    retail_day_of_year,
    retail_weeks_in_year,
    is_53_week_retail_year,
    is_retail_week_53,
    retail_year_start_date,
    retail_year_end_date,
    retail_quarter_start_date,
    retail_quarter_end_date,
    retail_period_start_date,
    retail_period_end_date,
    retail_week_start_date,
    retail_week_end_date,
    retail_year_period_int,
    retail_year_week_int,
    retail_year_period_label,
    comparable_date_ly,
    comparable_date_2ly,
    comparable_date_3ly,
    -- Pacing - FY
    fiscal_year_total_days,
    fiscal_days_elapsed,
    fiscal_year_total_days - fiscal_days_elapsed                          as fiscal_days_remaining,
    cast(round(fiscal_days_elapsed / cast(fiscal_year_total_days as double), 4) as decimal(9,4))
                                                                          as fiscal_year_pct_complete,
    -- Pacing - FM
    fiscal_month_total_days,
    fiscal_month_days_elapsed,
    fiscal_month_total_days - fiscal_month_days_elapsed                   as fiscal_month_days_remaining,
    cast(round(fiscal_month_days_elapsed / cast(fiscal_month_total_days as double), 4) as decimal(9,4))
                                                                          as fiscal_month_pct_complete,
    -- Pacing - FQ
    fiscal_quarter_total_days,
    fiscal_quarter_days_elapsed,
    fiscal_quarter_total_days - fiscal_quarter_days_elapsed               as fiscal_quarter_days_remaining,
    cast(round(fiscal_quarter_days_elapsed / cast(fiscal_quarter_total_days as double), 4) as decimal(9,4))
                                                                          as fiscal_quarter_pct_complete,
    -- Pacing - WD
    working_days_in_fiscal_year,
    working_days_elapsed_fy,
    working_days_in_fiscal_year - working_days_elapsed_fy                 as working_days_remaining_fy,
    working_days_in_fiscal_month,
    working_days_elapsed_fm,
    working_days_in_fiscal_month - working_days_elapsed_fm                as working_days_remaining_fm,
    -- Dynamic flags: recomputed on every dbt run (spec 2.6)
    date =  current_date()                                                as is_today,
    date <  current_date()                                                as is_past,
    date <= current_date()                                                as is_past_or_today,
    date >  current_date()                                                as is_future,
    current_date() between first_day_of_month and last_day_of_month       as is_current_calendar_month,
    current_date() between first_day_of_month and last_day_of_month       as is_current_fiscal_month,
    current_date() between retail_period_start_date and retail_period_end_date
                                                                          as is_current_retail_period,
    date >= add_months(trunc(current_date(), 'MM'), -13)
        and date <= current_date()                                        as is_last_13_months,
    -- Audit
    'dbt_generated'                                                       as source_system,
    current_timestamp()                                                   as gold_refresh_datetime
from with_pacing
