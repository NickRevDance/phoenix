{% macro flag_source_deletes(key_column, current_keys_relation) %}
    {#- Post-hook for silver tables over D365 extracts. D365 hard-deletes rows and an incremental
        merge never sees a delete, so the row is kept and marked: is_deleted = 1 and
        deleted_detected_datetime = the run that first found the key missing from
        current_keys_relation. A key that comes back is cleared. Rows loaded before the columns
        existed (NULL) are filled on the first run.
        Reload guard: when the extract holds fewer rows than source_delete_guard_ratio x the live
        rows already in silver (a BYOD reload in progress), the run flags and clears nothing. -#}
    {%- set guard_ratio = var('source_delete_guard_ratio', 0.995) -%}
merge into {{ this }} as t
using (
    select
          s.{{ key_column }}
        , k.{{ key_column }} is null as is_gone
    from {{ this }} s
    left join (select distinct c.{{ key_column }} from {{ current_keys_relation }} c) k
        on s.{{ key_column }} = k.{{ key_column }}
    where (select count(*) from {{ current_keys_relation }})
          >= {{ guard_ratio }} * (select count(*) from {{ this }} x where coalesce(x.is_deleted, 0) = 0)
      and (
            (k.{{ key_column }} is null and coalesce(s.is_deleted, 0) = 0)
         or (k.{{ key_column }} is not null and (s.is_deleted is null or s.is_deleted = 1))
      )
) as d
    on t.{{ key_column }} = d.{{ key_column }}
when matched and d.is_gone then update set
      t.is_deleted = 1
    , t.deleted_detected_datetime = current_timestamp()
when matched and not d.is_gone then update set
      t.is_deleted = 0
    , t.deleted_detected_datetime = cast(null as timestamp)
{% endmacro %}


{% macro sync_source_deleted_flag(fact_key_column, silver_relation, silver_key_column, key_salt=none, update_audit_column=none) %}
    {#- Post-hook for gold facts that keep source-deleted rows. Keeps is_source_deleted_flag in
        step with the silver is_deleted mark on every row, including rows outside the incremental
        window (a delete doesn't move MODIFIEDDATE, so the model's own merge never revisits the
        row), and fills the flag on rows loaded before the column existed. Only silver rows that
        are marked, and fact rows that are flagged or NULL, are read. The fact key must be
        xxhash64(silver key[, key_salt]). -#}
    {%- set fact_key_expr -%}xxhash64(s.{{ silver_key_column }}{% if key_salt %}, '{{ key_salt }}'{% endif %}){%- endset -%}
merge into {{ this }} as t
using (
    select
          {{ fact_key_expr }} as fact_key
        , coalesce(s.is_deleted, 0) = 1 as is_source_deleted
    from {{ silver_relation }} s
    where s.is_deleted = 1
       or {{ fact_key_expr }} in (
            select f.{{ fact_key_column }}
            from {{ this }} f
            where f.is_source_deleted_flag is null or f.is_source_deleted_flag
          )
) as d
    on t.{{ fact_key_column }} = d.fact_key
when matched and not (t.is_source_deleted_flag <=> d.is_source_deleted) then update set
      t.is_source_deleted_flag = d.is_source_deleted
    {%- if update_audit_column %}
    , t.{{ update_audit_column }} = current_timestamp()
    {%- endif %}
{% endmacro %}
