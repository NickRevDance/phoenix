{{ config(materialized = 'table') }}

{% set dim_product_columns = [
    'product_key',
    'product_id',
    'UPC',
    'upc_setup_id',
    'SKU',
    'barcode_id',
    'invent_dim_id',
    'source_system',
    'style_number',
    'style_name',
    'color_family',
    'colorway',
    'active_colorways',
    'd365_color_code',
    'code_color',
    'rgb_hex',
    'd365_product_color',
    'd365_product_color_size',
    'size',
    'size_range',
    'sales_size_chart',
    'product_group',
    'product_sub_group',
    'product_set',
    'product_subset',
    'product_summary',
    'summary_class',
    'module_type',
    'product_class',
    'classifier_3',
    'code_color_style_name',
    'brand',
    'genre',
    'sub_genre',
    'adult_child',
    'gender',
    'age_look',
    'selling_age_look',
    'division_season',
    'original_season',
    'original_season_fy',
    'sprint',
    'product_sprint',
    'debut_date',
    'debut_year',
    'retirement_date',
    'inactive_date',
    'Vintage',
    'Holiday',
    'plm_status',
    'erp_status',
    'dw_sku_status',
    'active_flag',
    'planning_flag',
    'product_supplier',
    'product_ownership',
    'shipping_vendor_id',
    'country_of_origin',
    'incoterm_code',
    'plm_estimated_landed_cost',
    'plm_estimated_freight_rate',
    'duty_percentage',
    'duty_calculated',
    'tariff_percent',
    'tariff_calculated',
    'currency_code',
    'product_weight',
    'product_weight_uom',
    'product_height',
    'product_height_uom',
    'product_width',
    'product_width_uom',
    'product_depth',
    'product_depth_uom',
    'product_volume',
    'product_volume_uom',
    'Density',
    'product_quantity_uom',
    'Designer',
    'Model',
    'development_type',
    'garment_features',
    'sensory_friendly',
    'line_discount_group',
    'tax_item_group_id',
    'Classification',
    'hts_code_duty_composition',
    'hero_image_aws_link',
    'website_url',
    'is_bc_upload_done',
    'colorways_market_entry_date',
    'colorways_market_exit_date',
    'case_id',
    'Factor',
    'style_level_leadtime_to_x_factory',
    'product_change_hash',
    'row_hash',
    'effective_start_datetime',
    'effective_end_datetime',
    'record_source_table',
    'etl_update_datetime',
    'retirement_year',
    'version_number',
    'is_current_row'
] %}

WITH business_products AS (

SELECT
    snap_p.* EXCEPT(
        ItemBarcode
        ,Pv_DisplayProductNumber
        ,SearchKeywords
        ,BOMMaterials
        ,MainMaterial
        ,CatalogDescriptionBullets
        ,WebsiteHTMLDescriptionBlock
        ,IncludesBullets
        ,CompProducts
        ,CompetitiveStyles
        ,LanguageID
        ,ShopbyEdit
        ,YoutubeID
        ,AdditionalWebGenres
        ,RecentConversations
        ,Drops
        ,Promotions
        ,TippieToesHalo
        ,CategorySpecials
        ,BigIdea
        ,PriceApplicableDate
        ,CPSCStyleCompliant
        ,CPSCStyleCompliantDate
        ,CPSCStyleExpiration
        , dbt_updated_at
    )
    , {{ scd2_version_number('product_key') }} as version_number
    , {{ scd2_is_current_row() }} as is_current_row
FROM
    {{ref("silver_snapshot_dim_product")}} snap_p
WHERE
    -- DIM_PRODUCT population rule (Sep 28 2026): a dimension row requires a
    -- D365 item. A Centric variant flagged Completed before D365 has its
    -- barcode lands in the snapshot with NULL product_id; keep it out of
    -- gold until D365 catches up. See DIM_PRODUCT v1.3 sec 3.5.
    snap_p.product_id IS NOT NULL

),

reserved_members AS (

    -- Reserved Unknown member (product_key = -1) per the project reserved-member
    -- convention. Facts fall back to -1 when a barcode or item cannot be resolved to a
    -- dimension row; this row gives those facts a valid key to land on. Hardcoded
    -- literal, not derived by hashing. Both sides are selected through the explicit column list below, so the
    -- snapshot's physical column order does not matter.

    SELECT
        cast({{ unknown_member_key() }} as string) as product_key
        , cast('UNKNOWN' as string) as product_id
        , cast(null as varchar(20)) as UPC
        , cast(null as varchar(30)) as upc_setup_id
        , cast('UNKNOWN' as string) as SKU
        , cast(null as string) as barcode_id
        , cast(null as string) as invent_dim_id
        , cast('Manual Seed' as string) as source_system
        , cast('UNKNOWN' as varchar(30)) as style_number
        , cast('Unknown Product' as varchar(100)) as style_name
        , cast(null as varchar(50)) as color_family
        , cast(null as varchar(30)) as colorway
        , cast(null as varchar(200)) as active_colorways
        , cast(null as varchar(50)) as d365_color_code
        , cast(null as string) as code_color
        , cast(null as varchar(7)) as rgb_hex
        , cast(null as string) as d365_product_color
        , cast(null as string) as d365_product_color_size
        , cast(null as varchar(20)) as size
        , cast(null as varchar(50)) as size_range
        , cast(null as varchar(50)) as sales_size_chart
        , cast('Unknown' as varchar(50)) as product_group
        , cast('Unknown' as varchar(50)) as product_sub_group
        , cast(null as varchar(50)) as product_set
        , cast(null as varchar(50)) as product_subset
        , cast(null as varchar(50)) as product_summary
        , cast('Unknown' as string) as summary_class
        , cast(null as int) as module_type
        , cast(null as string) as product_class
        , cast(null as varchar(100)) as classifier_3
        , cast(null as string) as code_color_style_name
        , cast(null as varchar(50)) as brand
        , cast(null as varchar(50)) as genre
        , cast(null as varchar(50)) as sub_genre
        , cast(null as varchar(10)) as adult_child
        , cast(null as varchar(10)) as gender
        , cast(null as varchar(20)) as age_look
        , cast(null as varchar(20)) as selling_age_look
        , cast(null as varchar(20)) as division_season
        , cast(null as varchar(4)) as original_season
        , cast(null as string) as original_season_fy
        , cast(null as varchar(30)) as sprint
        , cast(null as varchar(50)) as product_sprint
        , cast(null as date) as debut_date
        , cast(null as int) as debut_year
        , cast(null as timestamp) as retirement_date
        , cast(null as timestamp) as inactive_date
        , cast(null as boolean) as Vintage
        , cast(null as varchar(20)) as Holiday
        , cast(null as varchar(30)) as plm_status
        , cast(null as string) as erp_status
        , cast(null as string) as dw_sku_status
        , true as active_flag
        , cast(null as varchar(200)) as planning_flag
        , cast(null as varchar(50)) as product_supplier
        , cast(null as string) as product_ownership
        , cast(null as varchar(50)) as shipping_vendor_id
        , cast(null as varchar(20)) as country_of_origin
        , cast(null as string) as incoterm_code
        , cast(null as decimal(18,8)) as plm_estimated_landed_cost
        , cast(null as decimal(18,8)) as plm_estimated_freight_rate
        , cast(null as decimal(18,8)) as duty_percentage
        , cast(null as decimal(18,8)) as duty_calculated
        , cast(null as decimal(18,8)) as tariff_percent
        , cast(null as decimal(18,8)) as tariff_calculated
        , cast(null as string) as currency_code
        , cast(null as decimal(18,8)) as product_weight
        , cast(null as varchar(30)) as product_weight_uom
        , cast(null as decimal(18,8)) as product_height
        , cast(null as varchar(30)) as product_height_uom
        , cast(null as decimal(18,8)) as product_width
        , cast(null as varchar(30)) as product_width_uom
        , cast(null as decimal(18,8)) as product_depth
        , cast(null as varchar(30)) as product_depth_uom
        , cast(null as decimal(18,8)) as product_volume
        , cast(null as varchar(30)) as product_volume_uom
        , cast(null as decimal(32,6)) as Density
        , cast(null as varchar(10)) as product_quantity_uom
        , cast(null as varchar(100)) as Designer
        , cast(null as varchar(100)) as Model
        , cast(null as varchar(100)) as development_type
        , cast(null as varchar(100)) as garment_features
        , cast(null as varchar(100)) as sensory_friendly
        , cast(null as string) as line_discount_group
        , cast(null as varchar(20)) as tax_item_group_id
        , cast(null as varchar(20)) as Classification
        , cast(null as string) as hts_code_duty_composition
        , cast(null as varchar(2083)) as hero_image_aws_link
        , cast(null as varchar(2083)) as website_url
        , cast(null as string) as is_bc_upload_done
        , cast(null as date) as colorways_market_entry_date
        , cast(null as date) as colorways_market_exit_date
        , cast(null as varchar(200)) as case_id
        , cast(null as int) as Factor
        , cast(null as int) as style_level_leadtime_to_x_factory
        , cast('Reserved member -- not derived from a hash.' as string) as product_change_hash
        , cast('RESERVED' as string) as row_hash
        , cast(null as timestamp) as effective_start_datetime
        , cast(null as timestamp) as effective_end_datetime
        , cast('Manual Seed' as string) as record_source_table
        , current_timestamp() as etl_update_datetime
        , cast(null as int) as retirement_year
        , cast(1 as int) as version_number
        , cast(1 as int) as is_current_row

)

SELECT
    {%- for c in dim_product_columns %}
    {{ ', ' if not loop.first }}`{{ c }}`
    {%- endfor %}
FROM business_products

UNION ALL

SELECT
    {%- for c in dim_product_columns %}
    {{ ', ' if not loop.first }}`{{ c }}`
    {%- endfor %}
FROM reserved_members
