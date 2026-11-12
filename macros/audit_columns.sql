{% macro audit_columns(insert_from=none, update_from=none) %}
{#-
    Project-standard audit columns: etl_insert_datetime and etl_update_datetime,
    both timestamp (UTC). Call it in the select list after the last business
    column, with a leading comma:

        , {{ audit_columns() }}

    insert_from / update_from take a column expression; either one left out
    defaults to current_timestamp(). The patterns in use:

      - Table rebuild (ref tables, reserved dimension members):
            , {{ audit_columns() }}

      - Snapshot-fed SCD2 dimension or fact. The version's start is when the
        row was first written, and the snapshot's dbt_updated_at (remapped to
        etl_update_datetime) is when it was last touched:
            , {{ audit_columns(insert_from='snap.effective_start_datetime',
                               update_from='snap.etl_update_datetime') }}

      - Incremental merge that holds the first insert time. Either read the
        existing row back in:
            , {{ audit_columns(insert_from='coalesce(ex.etl_insert_datetime, current_timestamp())') }}
        or keep the default and add etl_insert_datetime to merge_exclude_columns.

    row_hash is not an audit column of this macro: in snapshot-fed models it is
    the snapshot's dbt_scd_id, and a change hash comes from generate_row_hash().
-#}
{{ insert_from if insert_from else 'current_timestamp()' }} as etl_insert_datetime
        , {{ update_from if update_from else 'current_timestamp()' }} as etl_update_datetime
{%- endmacro %}
