{{ config(materialized = 'table') }}
 
SELECT
    *
FROM
    {{ ref("bronze_d365_dir_party") }}
 