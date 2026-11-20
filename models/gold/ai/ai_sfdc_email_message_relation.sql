{{ config(alias = 'sfdc_email_message_relation') }}

select
    s.*
from {{ ref('bronze_sfdc_email_message_relation') }} as s
