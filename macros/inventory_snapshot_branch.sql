{% macro inventory_snapshot_branch_label(branch) -%}
{#-
    EDW-117 item 5: record_source_table on fact_inventory_snapshot_daily is a
    branch constant, not the physical staging name (Inventory spec v2.4+,
    Section 2.2 / 2.5). Every model that stamps or filters on it goes through
    this macro so a source rename can never split one branch into two labels
    again (the Sep 1 2026 'silver_byod_...' drift excluded a day from the
    reconciliation view). The literal values are the ones already stamped on
    prod history, kept so no rewrite is needed.
-#}
{%- if branch == 'native' -%}
'silver_d365_inventory_sum + silver_d365_inventory_dim'
{%- elif branch == 'backfill' -%}
'silver_kpi_inventory_value'
{%- else -%}
{{ exceptions.raise_compiler_error("inventory_snapshot_branch_label: branch must be 'native' or 'backfill', got '" ~ branch ~ "'") }}
{%- endif -%}
{%- endmacro %}

{% macro inventory_snapshot_native_start_date() -%}
{#-
    Fixed seam between the legacy backfill branch and the native InventSum
    branch (spec 2.5 rule 4, 2.6 go-live table). Never a runtime date.
    EDW-117 item 2: moved from 2026-08-21 to 2026-09-01 because prod's native
    history begins Sep 1 (the Aug 21-31 native days were lost to the Sep 1
    full refresh) and the legacy feed holds those days.
-#}
'2026-09-01'
{%- endmacro %}