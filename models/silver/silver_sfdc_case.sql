{{ config(materialized = 'table') }}

-- All SCD2 versions: pre-cutover history from phoenix_raw.manual, closed where the phoenix_raw versions start.
{{ union_scd2_history(ref('bronze_sfdc_case_pre_cutover'), ref('bronze_sfdc_case')) }}
