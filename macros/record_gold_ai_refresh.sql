{% macro record_gold_ai_refresh() %}
  {% set tbl = target.database ~ '.' ~ target.schema ~ '_gold_ai.refresh_log' %}
  {% do run_query(
      "CREATE TABLE IF NOT EXISTS " ~ tbl ~ " (
          refreshed_at TIMESTAMP,
          dbt_job_id STRING,
          dbt_run_id STRING,
          salesforce_data_as_of TIMESTAMP
      )"
  ) %}
  {% do run_query(
      "INSERT INTO " ~ tbl ~ "
       SELECT
           current_timestamp()
         , '" ~ env_var('DBT_CLOUD_JOB_ID', 'manual') ~ "'
         , '" ~ env_var('DBT_CLOUD_RUN_ID', 'manual') ~ "'
         , (SELECT max(a.SystemModstamp) FROM " ~ ref('silver_sfdc_account') ~ " a)"
  ) %}
{% endmacro %}