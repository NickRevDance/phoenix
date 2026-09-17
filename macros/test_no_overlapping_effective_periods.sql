{% test no_overlapping_effective_periods(model, partition_by, from_column='effective_from_date', to_column='effective_to_date') %}
{#
  Flags overlapping effective-dated windows within the same natural-key
  partition -- REF_SLA_TARGET spec Section 8 requires "non-overlapping
  effective windows" as a consumption-rule test. Self-joins the model to
  itself on partition_by and compares [from_column, to_column) windows; a
  NULL to_column means "still current" and is treated as open-ended
  (far-future) for the comparison. Only the a.period_start < b.period_start
  direction of each pair is kept, so a true overlap is reported once, not
  twice.

  Args:
    model:        supplied automatically by dbt
    partition_by: list of column names forming the natural key EXCLUDING
                  the effective-date columns themselves (e.g.
                  ['metric_code', 'business_unit_code', 'scope_type', 'scope_code'])
    from_column / to_column: effective-window column names
#}

with windows as (

    select
          concat_ws('||', {{ partition_by | join(', ') }}) as natural_key
        , {{ from_column }} as period_start
        , coalesce({{ to_column }}, date('9999-12-31')) as period_end
    from {{ model }}

)

select
      a.natural_key
    , a.period_start as period_a_start
    , a.period_end   as period_a_end
    , b.period_start as period_b_start
    , b.period_end   as period_b_end
from windows a
join windows b
    on a.natural_key = b.natural_key
    and a.period_start < b.period_start
where a.period_end > b.period_start

{% endtest %}
