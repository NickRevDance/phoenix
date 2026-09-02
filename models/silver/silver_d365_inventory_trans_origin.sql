
{{ config(
    materialized = 'incremental',
    unique_key = 'RECID',
    incremental_strategy = 'merge'
) }}
 
select
    *
from
    {{ref("bronze_d365_inventory_trans_origin")}}
 
{% if is_incremental() %}
where SYNCSTARTDATETIME > (select coalesce(max(SYNCSTARTDATETIME), timestamp('1900-01-01')) from {{ this }}) - interval 2 days
{% endif %}
 