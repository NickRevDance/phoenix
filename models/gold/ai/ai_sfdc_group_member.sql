{{ config(alias = 'sfdc_group_member') }}

select
    s.*
from {{ ref('silver_sfdc_group_member') }} as s
