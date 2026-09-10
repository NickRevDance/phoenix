{% test relationship_coverage(model, column_name, to, field, where=None, to_where=None) %}
{#
  Generic coverage test: fails on any value of `model.column_name` that does NOT
  appear anywhere in `to.field`. This is the reverse of the built-in `relationships`
  test (which checks a child's FK values against a parent's business key) -- here
  the model this test is attached to is the "parent"/business-key side, and
  `to`/`field` point at the table+column that is supposed to reference every one
  of its values at least once.

  Built to be reusable across any lookup/crosswalk relationship in this project,
  not tied to one dataset -- e.g. attach it to DIM_SALES_CHANNEL.channel_code with
  to=ref('ref_sales_origin_map'), field=channel_code, where="channel_status =
  'Active'" to confirm every active channel has at least one origin code mapped to
  it. The same macro works for any other "every X in table A must appear somewhere
  in table B" check by pointing model/column_name/to/field at a different pair.

  Args:
    model:       the parent table (this test is attached to one of its columns in yml)
    column_name: the parent's business-key column that must be fully covered
    to:          the referencing/mapping relation, e.g. ref('some_model')
    field:       the column on `to` expected to contain every column_name value
    where:       optional filter on the parent side, e.g. only check active rows
    to_where:    optional filter on the `to` side, e.g. only count confirmed rows
#}

with parent_values as (

    select distinct {{ column_name }} as value
    from {{ model }}
    {% if where %} where {{ where }} {% endif %}

),

covered_values as (

    select distinct {{ field }} as value
    from {{ to }}
    {% if to_where %} where {{ to_where }} {% endif %}

)

select p.value
from parent_values p
left join covered_values c on p.value = c.value
where c.value is null

{% endtest %}
