{{ config(materialized = 'view') }}

SELECT
    *
FROM
    {{source("dwhvisualnext_dimensions", "date")}}