{% macro record_gold_ai_refresh() %}
  {% set tbl = target.database ~ '.' ~ target.schema ~ '_gold_ai.refresh_log' %}
  {% set rel = api.Relation.create(database=target.database, schema=target.schema ~ '_gold_ai', identifier='refresh_log') %}

  {% do run_query(
      "CREATE TABLE IF NOT EXISTS " ~ tbl ~ " (
          refreshed_at TIMESTAMP,
          dbt_job_id STRING,
          dbt_run_id STRING,
          salesforce_data_as_of TIMESTAMP,
          is_new_salesforce_data BOOLEAN
      )"
  ) %}

  {% set existing_cols = adapter.get_columns_in_relation(rel) | map(attribute='name') | map('lower') | list %}
  {% if 'is_new_salesforce_data' not in existing_cols %}
    {% do run_query("ALTER TABLE " ~ tbl ~ " ADD COLUMN is_new_salesforce_data BOOLEAN") %}
  {% endif %}

  {% do run_query(
      "INSERT INTO " ~ tbl ~ " (refreshed_at, dbt_job_id, dbt_run_id, salesforce_data_as_of, is_new_salesforce_data)
       SELECT
           current_timestamp()
         , '" ~ env_var('DBT_CLOUD_JOB_ID', 'manual') ~ "'
         , '" ~ env_var('DBT_CLOUD_RUN_ID', 'manual') ~ "'
         , n.salesforce_data_as_of
         , CASE
               WHEN n.salesforce_data_as_of IS NULL THEN false
               WHEN p.prior_as_of IS NULL THEN true
               ELSE n.salesforce_data_as_of > p.prior_as_of
           END
       FROM (SELECT max(a.SystemModstamp) AS salesforce_data_as_of FROM " ~ ref('silver_sfdc_account') ~ " a) n
       CROSS JOIN (SELECT max(l.salesforce_data_as_of) AS prior_as_of FROM " ~ tbl ~ " l) p"
  ) %}
{% endmacro %}