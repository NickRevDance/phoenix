{{ config(materialized = 'table') }}

SELECT
-- Core Identifiers
    md5(concat_ws('|',ifnull(CPM.UPC,'0'))) AS product_key
    ,BAR.ItemID as product_id
    ,CPM.UPC
    ,CPM.BarcodeSetupID AS upc_setup_id
    ,CPM.SKU
    ,BAR.barcode_id
    ,BAR.InventDimID as invent_dim_id --used to match to inventory
    , 'D365' as source_system
--Style and Color
    ,CPM.`Style#` AS style_number
    ,CPM.StyleName as style_name
    ,CPM.ColorFamily as color_family
    ,CPM.Colorway as colorway
    ,CPM.ActiveColorways as active_colorways
    ,CPM.D365ColorCode as d365_color_code
    ,CPM.CodeColor as code_color
    ,CPM.RGBHex as rgb_hex
    , '' as d365_product_color -- D365 product color composite. From view.
    , '' as d365_product_color_size -- D365 product+color+size composite. From view.
-- Size
    ,CPM.Size as size
    ,CPM.SizeRange as size_range
    ,CPM.SalesSizeChart as size_range_chart
-- Hierarchy
    ,CPM.ProductGroup as product_group
    ,CPM.ProductSubGroup as product_subgroup
    ,CPM.ProductSet as product_set
    ,CPM.ProductSubset as product_subset
    ,CPM.ProductSummary as product_summary
    , '' as summary_class --Reporting summary class (e.g., Revolution Costume, Art Stone Costumes). Critical for Finance/Ops slicing. Currently derived in view — should be stored.
    ,MODU.ModuleType as mudule_type
    ,PV.ProductClass as product_class
    ,CPM.Classifier3 as classifier_3
    , '' as code_color_style_name -- Composite: code_color + style_name for display. From view.
-- Brand and Genre
    ,CPM.Brand as brand
    ,CPM.Genre as genre
    ,CPM.SubGenre as sub_genre
--Demographics
    ,CPM.AdultChild as adult_child
    ,CPM.Gender as gender
    ,CPM.AgeLook as age_look
    ,CPM.SellingAgeLook as selling_age_look
-- Season and Lifestyle
    ,CPM.ParentSeason AS division_season
    ,CPM.OriginalSeason as original_season
    , '' as original_season_fy -- Original season as fiscal year (e.g., FY27). From view.
    ,CPM.SprintOperations AS sprint
    ,CPM.ProductSprint as prooduct_sprint
    ,CPM.DebutDate as debut_date
    ,CPM.DebutYear as debut_year
    ,IDC.REVRETIREMENTDATE AS retirement_date
    ,IDC.REVINACTIVEDATE AS inactive_date
    ,CPM.Vintage
    ,CPM.Holiday
-- Status
    ,CPM.ProductStatus AS plm_status
    ,IDC.SUNTAFITEMSTATUS AS erp_status
    , '' as dw_sku_status -- Data warehouse SKU status (Active, Retired). From view.
    ,CPM.Active as active_flag
    ,CPM.PlanningFlag as planning_flag
-- Sourcing
    ,CPM.ProductSupplier as product_supplier
    ,CPM.ProductOwnership as product_ownership
    ,CPM.ShippingVendorID as shipping_vendor_id
    ,CPM.CountryOfOrigin as country_of_origin
    , '' as incoterm_code -- Incoterm if maintained at product level. Phase 2
-- Cost Reference
    ,CPM.EstimatedLandedCost AS plm_estimated_landed_cost
    ,CPM.FreightRate AS plm_estimated_freight_rate
    ,CPM.DutyPercentage as duty_percentage
    ,CPM.DutyCalculated as duty_calculated
    ,CPM.TariffPercent as tariff_percentage
    ,CPM.TariffCalculated as tariff_calculated
    ,'USD' AS currency_code
-- Physical attributes
    ,CPM.ProductWeight as product_weight
    ,CPM.ProductWeightUOM as product_weight_uom
    ,CPM.ProductHeight as product_height
    ,CPM.ProductHeightUOM as product_height_uom
    ,CPM.ProductWidth as product_width
    ,CPM.ProductWidthUOM as product_width_uom
    ,CPM.ProductDepth as product_depth
    ,CPM.ProductDepthUOM as product_depth_uom
    ,CPM.ProductVolume as product_volume
    ,CPM.ProductVolumeUOM as product_volume_uom
    ,INV.Density
    ,CPM.ProductQuantityUOM as product_quantity_uom
-- Design
    ,CPM.Designer
    ,CPM.Model
    ,CPM.DevelopmentType as development_type
    ,CPM.GarmentFeatures as garment_features
    ,CPM.SensoryFriendly as sensory_friendly
-- Commerce
    ,MODU.LineDisc AS line_discount_group
    ,CPM.TaxItemGroupID as tax_item_group_id
    ,CPM.Classification
    ,HTS.HTSCodeDutyComposition as hts_code_duty_composition
    ,CPM.HeroImageAWSLink as hero_image_aws_link
    ,CPM.WebsiteURL as website_url
    ,'' as is_bc_upload_done -- BigCommerce upload completion flag.
-- Colorway Dates
    ,CPM.MarketIntroDate AS colorways_market_entry_date
    ,CPM.MarketExitDate AS colorways_market_exit_date
-- PLM Reference
    ,CPM.CaseID as case_id
    ,CPM.Factor
    ,CPM.StyleLevelLeadtimeToXFactory as style_level_leadtime_to_x_factory
--Legacy
    ,BAR.ItemBarcode
    ,PV.DisplayProductNumber as pv_DisplayProductNumber
    ,CPM.SearchKeywords
    ,CPM.BOMMaterials
    ,CPM.MainMaterial
    ,CPM.CatalogDescriptionBullets
    ,CPM.WebsiteHTMLDescriptionBlock
    ,CPM.IncludesBullets
    ,CPM.CompProductsSimilarStyles AS CompProducts
    ,CPM.CompetitiveStyles
    ,'en-US' AS LanguageID
    ,CPM.ShopbyEdit
    ,CPM.YouTubeLink AS YoutubeID
    ,CPM.AdditionalWebGenres
    ,CPM.RecentConversations
    ,CPM.Drops
    ,CPM.Promotions
    ,CPM.TippieToesHalo
    ,CPM.CategorySpecials
    ,CPM.BigIdea
    ,CPM.PriceApplicableDate
    ,CPM.CPSCStyleCompliant
    ,CPM.CPSCStyleCompliantDate
    ,CPM.CPSCStyleExpiration
-- SCD2 change hash 
    -- this key is used to identify the fields used in SCD2. If more fields need to be tracked they should be added to this list
    , md5
        (
        concat_ws
            (
            '|'
            , style_name
            , colorway
            , color_family
            , product_group
            , product_subgroup
            , product_set
            , product_subset
            , product_summary
            , summary_class
            , classifier_3
            , brand
            , genre
            , sub_genre
            , adult_child
            , gender
            , age_look
            , selling_age_look
            , retirement_date
            , plm_status
            , erp_status
            , dw_sku_status
            , active_flag
            , product_supplier
            , country_of_origin
            , plm_estimated_landed_cost
            , plm_estimated_freight_rate
            , duty_percentage
            , duty_calculated
            , tariff_percentage
            , tariff_calculated
            )
        )
    as product_change_hash
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