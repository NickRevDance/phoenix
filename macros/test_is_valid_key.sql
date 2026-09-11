{% test is_valid_key(model, column_name) %}
{#
  Bundles this project's baseline "key" check -- not null AND unique --
  into one reusable generic test, so a model's primary/business key
  column gets a single `tests: [is_valid_key]` entry instead of the same
  `[not_null, unique]` pair retyped in every model's yml. Change what
  "valid key" means for this project in one place (this file) instead of
  every model that uses it.

  Only use this on a column that must be BOTH not-null AND unique (a
  true primary/business key). A column that only needs one of the two
  (e.g. a required-but-repeatable foreign key, or a nullable-but-unique
  code) should still use the built-in `not_null`/`unique` tests directly
  -- this macro is a bundle for the common case, not a replacement for
  either check on its own.

  Returns one row per failing value, tagged with which check it failed
  (`null` vs `duplicate`), so a failure doesn't lose the triage signal
  you'd get from running not_null/unique as two separate tests.

  Args:
    model:       the model being tested (supplied automatically by dbt)
    column_name: the key column to check (supplied automatically by dbt)
#}

with null_check as (

    select
          {{ column_name }} as key_value
        , 'null' as failure_reason
    from {{ model }}
    where {{ column_name }} is null

),

duplicate_check as (

    select
          {{ column_name }} as key_value
        , 'duplicate' as failure_reason
    from {{ model }}
    group by {{ column_name }}
    having count(*) > 1

)

select * from null_check
union all
select * from duplicate_check

{% endtest %}
