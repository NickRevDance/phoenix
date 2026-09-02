{% macro drop_orphaned_relations(dry_run=true) %}
{#
  Finds tables/views in schemas this project writes to that no longer match any
  current model, snapshot, or seed, and drops them.

  Usage:
    dbt run-operation drop_orphaned_relations                        -- dry run, logs only
    dbt run-operation drop_orphaned_relations --args '{dry_run: false}'  -- actually drops

  Scope (which schemas get scanned) is derived from graph.nodes -- only database.schema
  combos this project's models/snapshots/seeds currently write to, so it can't wander
  into a schema dbt doesn't know about. Run manually / on a schedule, not wired to
  on-run-end -- a branch that's temporarily missing a model shouldn't cause a drop.

  Sources (graph.sources) are excluded from the drop candidates even though they
  aren't part of graph.nodes -- as of this project's current sources.yml, every
  source lives in a schema this macro never scans anyway (raw d365_byod / dev-catalog
  schemas, not prod_bronze/prod_silver/prod_gold), so this is defensive rather than
  load-bearing today. It matters the moment that stops being true -- e.g. a future
  source landing in a schema a model also writes to -- so source identifiers are
  folded into known_relations regardless.
#}
{% if not execute %}
  {{ return(none) }}
{% endif %}

{% set known_relations = [] %}
{% set target_db_schemas = [] %}
{% for node in graph.nodes.values()
     | selectattr("resource_type", "in", ["model", "snapshot", "seed"]) %}
  {% do known_relations.append(node.schema ~ '.' ~ (node.alias or node.name)) %}
  {% do target_db_schemas.append(node.database ~ '.' ~ node.schema) %}
{% endfor %}
{% for src in graph.sources.values() %}
  {% do known_relations.append(src.schema ~ '.' ~ src.identifier) %}
{% endfor %}
{% set known_relations = known_relations | unique | list %}
{% set target_db_schemas = target_db_schemas | unique | list %}

{% set orphans = [] %}
{% for db_schema in target_db_schemas %}
  {% set database = db_schema.split('.')[0] %}
  {% set schema = db_schema.split('.')[1] %}
  {% set query %}
    select table_schema, table_name, table_type
    from {{ database }}.information_schema.tables
    where table_schema = '{{ schema }}'
  {% endset %}
  {% set results = run_query(query) %}
  {% for row in results.rows %}
    {% set full_name = row['table_schema'] ~ '.' ~ row['table_name'] %}
    {% if full_name not in known_relations %}
      {% do orphans.append({
        'database': database,
        'schema': row['table_schema'],
        'name': row['table_name'],
        'type': row['table_type']
      }) %}
    {% endif %}
  {% endfor %}
{% endfor %}

{% if orphans | length == 0 %}
  {{ log("No orphaned relations found.", info=true) }}
{% else %}
  {{ log(orphans | length ~ " orphaned relation(s) found:", info=true) }}
  {% for rel in orphans %}
    {% set drop_kind = 'view' if rel['type'] == 'VIEW' else 'table' %}
    {% set full_ref = rel['database'] ~ '.' ~ rel['schema'] ~ '.' ~ rel['name'] %}
    {% if dry_run %}
      {{ log("  [DRY RUN] would drop " ~ drop_kind ~ ": " ~ full_ref, info=true) }}
    {% else %}
      {{ log("  dropping " ~ drop_kind ~ ": " ~ full_ref, info=true) }}
      {% do run_query("drop " ~ drop_kind ~ " if exists " ~ full_ref) %}
    {% endif %}
  {% endfor %}
{% endif %}

{% endmacro %}
