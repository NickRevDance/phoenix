{{ config(materialized = 'table') }}

SELECT
    {{dbt_utils.generate_surrogate_key(['BAR.InventDimID', 'BAR.ItemID']) }} AS product_dim_id
    ,BAR.barcode_id
    ,BAR.ItemBarcode
    ,BAR.InventDimID
    ,BAR.ItemID
    ,PV.DisplayProductNumber as pv_DisplayProductNumber
    ,CPM.UPC
    ,CPM.BarcodeSetupID AS UPCSetupID
    ,CPM.SKU
    ,CPM.`Style#` AS StyleNumber
    ,CPM.StyleName
    ,CPM.Size
    ,CPM.SizeRange
    ,CPM.SalesSizeChart
    ,CPM.Colorway
    ,CPM.ColorFamily
    ,CPM.ActiveColorways
    ,CPM.D365ColorCode
    ,CPM.CodeColor
    ,CPM.RGBHex
    ,CPM.MarketIntroDate AS ColorwaysMarketEntryDate
    ,CPM.MarketExitDate AS ColorwaysMarketExitDate
    ,CPM.ParentSeason AS DivisionSeason
    ,CPM.OriginalSeason
    ,CPM.ProductStatus AS PLMStatus
    ,IDC.SUNTAFITEMSTATUS AS ERPStatus
    ,CPM.ProductQuantityUOM
    ,CPM.AdultChild
    ,CPM.Gender
    ,CPM.Vintage
    ,CPM.Active
    ,CPM.SprintOperations AS Sprint
    ,CPM.SearchKeywords
    ,CPM.ProductSupplier
    ,CPM.ProductOwnership
    ,CPM.ProductGroup
    ,CPM.ProductSubGroup
    ,CPM.ProductSet
    ,CPM.ProductSubset
    ,CPM.ProductSummary
    ,MODU.ModuleType
    ,PV.ProductClass
    ,CPM.Brand
    ,CPM.Genre
    ,CPM.SubGenre
    ,CPM.AgeLook
    ,CPM.SellingAgeLook
    ,CPM.BOMMaterials
    ,CPM.MainMaterial
    ,CPM.Model
    ,CPM.ProductDepth
    ,CPM.ProductDepthUOM
    ,CPM.ProductHeight
    ,CPM.ProductHeightUOM
    ,CPM.ProductWeight
    ,CPM.ProductWeightUOM
    ,CPM.ProductWidth
    ,CPM.ProductWidthUOM
    ,CPM.ProductVolume
    ,CPM.ProductVolumeUOM
    ,INV.Density
    ,CPM.DebutDate
    ,CPM.DebutYear
    ,IDC.REVRETIREMENTDATE AS RetirementDate
    ,IDC.REVINACTIVEDATE AS InactiveDate
    ,CPM.CatalogDescriptionBullets
    ,CPM.WebsiteHTMLDescriptionBlock
    ,CPM.IncludesBullets
    ,CPM.CompProductsSimilarStyles AS CompProducts
    ,CPM.CompetitiveStyles
    ,HTS.HTSCodeDutyComposition
    ,CPM.CountryOfOrigin
    ,CPM.ShippingVendorID
    ,'USD' AS Currency
    ,'en-US' AS LanguageID
    ,CPM.EstimatedLandedCost AS PLMEstimatedLandedCost
    ,CPM.FreightRate AS PLMEstimatedFreightRate
    ,CPM.Designer
    ,CPM.CaseID
    ,CPM.Factor
    ,CPM.Holiday
    ,CPM.GarmentFeatures
    ,CPM.Classification
    ,CPM.HeroImageAWSLink
    ,MODU.LineDisc AS LineDiscountGroup
    ,CPM.SensoryFriendly
    ,CPM.ShopbyEdit
    ,CPM.TaxItemGroupID
    ,CPM.WebsiteURL
    ,CPM.YouTubeLink AS YoutubeID
    ,CPM.AdditionalWebGenres
    ,CPM.PlanningFlag
    ,CPM.DutyPercentage
    ,CPM.DutyCalculated
    ,CPM.Classifier3
    ,CPM.TariffPercent
    ,CPM.TariffCalculated
    ,CPM.ProductSprint
    ,CPM.DevelopmentType
    ,CPM.RecentConversations
    ,CPM.StyleLevelLeadtimeToXFactory
    ,CPM.Drops
    ,CPM.Promotions
    ,CPM.TippieToesHalo
    ,CPM.CategorySpecials
    ,CPM.BigIdea
    ,CPM.PriceApplicableDate
    ,CPM.CPSCStyleCompliant
    ,CPM.CPSCStyleCompliantDate
    ,CPM.CPSCStyleExpiration
FROM
    {{ ref('silver_centric_product_current') }} CPM
LEFT JOIN
    {{ ref('silver_byod_item_barcode') }} BAR
    ON CPM.UPC = BAR.ItemBarcode
LEFT JOIN
    {{ ref('bronze_byod_inventory_combinations') }} IDC
    ON IDC.ItemID = BAR.ItemID
    AND IDC.InventDimID = BAR.InventDimID
LEFT JOIN
    {{ ref('silver_byod_inventory_item') }} INV
    ON INV.ItemID = BAR.ItemID
LEFT JOIN
    {{ ref('silver_byod_inventory_module_sales') }} MODU
    ON MODU.ItemID = BAR.ItemID
LEFT JOIN
    {{ ref('silver_byod_product_variant') }} PV
    ON PV.DisplayProductNumber = CONCAT(
         CPM.`Style#`
        ,'|'
        ,CPM.D365ColorCode
        ,'|'
        ,CPM.Size
    )
LEFT JOIN
    {{ ref('silver_byod_hts_by_item') }} HTS
    ON HTS.ItemID = BAR.ItemID