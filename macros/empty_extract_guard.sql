{% macro empty_extract_guard(extract_relation, min_rows=1) %}
    {#- True when the upstream BYOD extract has fewer than min_rows rows AND this
        model already exists, so a silver table model can re-select its own last
        good contents instead of rebuilding empty while the export is mid-reload.
        First-ever build (no existing relation) never holds. -#}
    {% if not execute %}
        {{ return(false) }}
    {% endif %}

    {% set existing = adapter.get_relation(database=this.database, schema=this.schema, identifier=this.identifier) %}
    {% if existing is none %}
        {{ return(false) }}
    {% endif %}

    {% set result = run_query('select count(*) as n from ' ~ extract_relation) %}
    {% set n = result.columns[0].values()[0] | int %}

    {% if n < min_rows %}
        {{ log('EMPTY EXTRACT GUARD: ' ~ extract_relation ~ ' returned ' ~ n ~ ' rows (min ' ~ min_rows ~ '); holding previous contents of ' ~ this, info=True) }}
        {{ return(true) }}
    {% endif %}

    {{ return(false) }}
{% endmacro %}
