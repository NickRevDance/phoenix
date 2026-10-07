{{ config(materialized = 'table') }}

SELECT
      m.ITEMID
    , m.LINEDISC AS item_disc_group

FROM {{ ref('bronze_d365_inventory_table_module') }} m

WHERE m.MODULETYPE = 2  -- sales module
  AND m.LINEDISC <> ''

QUALIFY ROW_NUMBER() OVER (PARTITION BY m.ITEMID ORDER BY m.MODIFIEDDATE DESC) = 1
