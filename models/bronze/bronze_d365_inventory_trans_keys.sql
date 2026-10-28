{{ config(materialized = 'view') }}

-- EDW-177: the InventTrans keys in the current extract. bronze_d365_inventory_trans is incremental and
-- keeps rows D365 has deleted, so delete detection in silver reads this instead.
SELECT
    RECID
FROM
    {{ source('byod', 'd365_inventory_trans') }}
