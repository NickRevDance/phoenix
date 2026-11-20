{{ config(alias = 'sfdc_group_member') }}

select
    s.*
from {{ ref('bronze_sfdc_group_member') }} as s
