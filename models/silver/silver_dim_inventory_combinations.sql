select
    *
--    ic.REVRETIREMENTDATE AS RetirementDate
--    , ic.REVINACTIVEDATE AS InactiveDate
--   , ic.SUNTAFITEMSTATUS
--    , ic.ItemID
--    , ic.InventDimID
FROM
    {{ref('bronze_dim_inventory_combinations')}} ic