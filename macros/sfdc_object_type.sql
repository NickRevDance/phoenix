{% macro sfdc_object_type(id_column) %}
{#- Names the Salesforce object a polymorphic Id (WhatId, WhoId, OwnerId) points to, from its 3-character key prefix. -#}
case left({{ id_column }}, 3)
    when '001' then 'Account'
    when '003' then 'Contact'
    when '005' then 'User'
    when '006' then 'Opportunity'
    when '00G' then 'Queue'
    when '00Q' then 'Lead'
    when '01t' then 'Product'
    when '500' then 'Case'
    when '701' then 'Campaign'
    when 'a00' then 'Customer User'
    when 'a03' then 'Blend'
    when 'a0X' then 'Chargent Order'
    when 'a0c' then 'Chargent Order Item'
    when 'a0i' then 'RMA Line'
    when 'a0j' then 'RMA'
    when 'a2M' then 'Sales Order'
    when 'a2N' then 'Sales Product'
    else case when {{ id_column }} is null then null else 'Other' end
end
{%- endmacro %}
