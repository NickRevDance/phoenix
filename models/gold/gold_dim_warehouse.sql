SELECT
    '' as warehouse_key
    i_sum.inventsiteid as warehouse_id
    , 'D365' as source_system
    , '' as warehouse_name
From
    {{ref("silver_byod_inventory_sum")}} i_sum
    left join {{ref("silver_byod_inventory_dim")}} i_dim
        on i_sum.invent_dim_id = i_dim.invent_dim_id