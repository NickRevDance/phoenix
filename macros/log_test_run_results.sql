{% macro log_test_run_results(results) %}
{#
  on-run-end hook. Writes one row per test executed in this invocation into
  a persistent history table (dq_test_run_log), regardless of pass/warn/fail,
  so a dashboard can show test status trend over time -- not just what's
  failing right now (that's what each test's own store_failures table is
  for). Safe to run on every `dbt build`/`dbt test` invocation, including
  model-only runs (no test results -> no rows written, no error).
#}
{% if execute %}
  {% set log_schema = target.schema ~ '_dq_exceptions' %}
  {% set log_relation = api.Relation.create(
      database=target.database,
      schema=log_schema,
      identifier='dq_test_run_log'
  ) %}

  {% do run_query('create schema if not exists ' ~ target.database ~ '.' ~ log_schema) %}

  {% set create_sql %}
    create table if not exists {{ log_relation }} (
      run_started_at   timestamp,
      invocation_id    string,
      test_unique_id   string,
      test_name        string,
      test_type        string,
      model_name       string,
      column_name      string,
      severity         string,
      warn_if          string,
      error_if         string,
      status           string,
      failures         bigint,
      message          string,
      execution_time   double
    ) using delta
  {% endset %}
  {% do run_query(create_sql) %}

  {% set rows = [] %}
  {% for result in results %}
    {% if result.node.resource_type == 'test' %}
      {% set node = result.node %}
      {% set model_name = 'unknown' %}
      {% for dep in node.depends_on.nodes %}
        {% if dep.startswith('model.') %}
          {% set model_name = dep.split('.')[-1] %}
        {% endif %}
      {% endfor %}
      {% set message = (result.message or '') | replace("'", "''") | replace('\n', ' ') %}
      {% set test_type = node.test_metadata.name if node.test_metadata else node.name %}
      {% set warn_if = node.config.get('warn_if') %}
      {% set error_if = node.config.get('error_if') %}
      {% set row -%}
        (
          timestamp('{{ run_started_at }}'),
          '{{ invocation_id }}',
          '{{ node.unique_id }}',
          '{{ node.name }}',
          '{{ test_type }}',
          '{{ model_name }}',
          {{ "'" ~ node.column_name ~ "'" if node.column_name else 'null' }},
          '{{ node.config.get('severity', 'error') }}',
          {{ "'" ~ warn_if ~ "'" if warn_if else 'null' }},
          {{ "'" ~ error_if ~ "'" if error_if else 'null' }},
          '{{ result.status }}',
          {{ result.failures if result.failures is not none else 'null' }},
          '{{ message }}',
          {{ result.execution_time }}
        )
      {%- endset %}
      {% do rows.append(row) %}
    {% endif %}
  {% endfor %}

  {% if rows | length > 0 %}
    {% set insert_sql %}
      insert into {{ log_relation }} values
      {{ rows | join(',\n') }}
    {% endset %}
    {% do run_query(insert_sql) %}
  {% endif %}
{% endif %}
{% endmacro %}
