SELECT 
    IDC.REVRETIREMENTDATE AS RetirementDate
    , IDC.REVINACTIVEDATE AS InactiveDate
    , IDC.SUNTAFITEMSTATUS
    , IDC.ItemID
    , IDC.InventDimID
FROM 
    {{source('byod','inventory_combinations')}} IDC