{% test one_current_row_per_key(model, key_columns, current_column='is_current_row', end_column='effective_end_datetime') %}
{#
  EDW-132 section 1: exactly one current row per natural key on an SCD2 table. The
  companion to no_overlapping_effective_periods and kept separate from it, since a key can
  have clean, non-overlapping ranges and still carry two current rows or none.

  A key fails when it has more than one current row, or when it has no current row while
  one of its versions is still open (NULL end). A key whose versions are all closed reads
  zero current rows by the house rule (current = latest version and an open end,
  scd2_is_current_row): every snapshot runs hard_deletes: invalidate, which closes the
  open version of a record that leaves the source without a successor. That key is
  correct and passes. Reserved members (-1 / 0) are one open, current row each and pass.

  Returns one row per failing key with its counts and the reason.

  Args:
    model:          supplied automatically by dbt
    key_columns:    list of columns forming the natural key, i.e. what the snapshot
                    versions on (e.g. ['customer_key'] or
                    ['source_system', 'source_storefront_code', 'source_promotion_id'])
    current_column: the current-row flag; int 1/0 is the house standard (EDW-130), and
                    the cast lets a boolean flag work too
    end_column:     the SCD2 end column; NULL means the version is still open
#}

with keys as (

    select
          {{ key_columns | join('\n        , ') }}
        , count(*) as version_count
        , count_if(cast({{ current_column }} as int) = 1) as current_row_count
        , count_if({{ end_column }} is null) as open_version_count
    from {{ model }}
    group by {{ key_columns | join(', ') }}

)

select
      *
    , case
        when current_row_count > 1 then 'multiple current rows'
        else 'open version with no current row'
      end as failure_reason
from keys
where current_row_count > 1
   or (current_row_count = 0 and open_version_count > 0)

{% endtest %}