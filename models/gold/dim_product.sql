{{ config(materialized = 'table') }}

-- DIM_PRODUCT (spec v1.3). SCD2 product dimension at UPC grain, one row per product_key
-- version, plus two reserved members. EDW-151 (reserved members, Type 1 from the stage,
-- snake_case names) and EDW-125 (reporting rollups).
--
-- Column names: every output column is snake_case (spec 3.6). The snapshot and the stage still
-- carry nine mixed-case source names (UPC, SKU, Vintage, Holiday, Density, Designer, Model,
-- Classification, Factor). Databricks resolves names case-insensitively and names the output
-- column as it is written here, so the lists below ARE the naming contract: keep them lowercase.
--
-- Type 2 attributes and the SCD2 controls come from silver_snapshot_dim_product. The snapshot
-- versions only on product_change_hash, so a Type 1 correction never reaches it. Type 1
-- attributes are therefore read from the current silver_stage_dim_product row (spec Section 5,
-- the DIM_VENDOR / DIM_WAREHOUSE pattern) and apply to every version of the product. A product
-- that has left the stage (closed by hard_deletes: invalidate) has no stage row and keeps the
-- snapshot values. product_id keeps the snapshot value when the stage has none, so a row that
-- passed the population rule never loses its item.
--
-- Placeholder columns (EDW-118, spec 3.6): d365_product_color, d365_product_color_size,
-- code_color_style_name, original_season_fy, incoterm_code and is_bc_upload_done have no source.
-- They are typed NULLs written here, not read from the stage or the snapshot, so every version
-- row is NULL whatever the older snapshot rows hold ('') and is_bc_upload_done is boolean.
--
-- Population rule (spec 3.5, Sep 28 2026): a dimension row requires a D365 item. A Centric
-- variant flagged Completed before D365 has its barcode lands in the snapshot with a NULL
-- product_id; that version stays out of gold.
--
-- Reporting rollups (EDW-125): reporting_category_group, reporting_subcategory and
-- loyalty_reporting_category come from ref_summary_class_rollup on the version row's
-- summary_class, each with its sort column. A product whose summary class is NULL or has no
-- rollup row reads Other (sorts 9 / 99 / 9), so the rollups are never NULL and a category
-- total always ties to the grand total. The DQ signal for an unmapped product stays on
-- summary_class itself, which remains NULL.
--
-- Columns are named explicitly on both sides of the union, so the snapshot's physical column
-- order and its extra columns (web content, PLM notes, dbt_updated_at) never reach gold and
-- need no EXCEPT list.

-- Type 2: tracked in product_change_hash, read from the snapshot version row
{% set type2_columns = [
    'style_name',
    'colorway',
    'color_family',
    'product_group',
    'product_sub_group',
    'product_set',
    'product_subset',
    'product_summary',
    'summary_class',
    'classifier_3',
    'brand',
    'genre',
    'sub_genre',
    'adult_child',
    'gender',
    'age_look',
    'selling_age_look',
    'retirement_date',
    'retirement_year',
    'plm_status',
    'erp_status',
    'dw_sku_status',
    'active_flag',
    'product_supplier',
    'country_of_origin',
    'plm_estimated_landed_cost',
    'plm_estimated_freight_rate',
    'duty_percentage',
    'duty_calculated',
    'tariff_percent',
    'tariff_calculated'
] %}

-- Type 1: read from the current stage row
{% set type1_columns = [
    'upc',
    'upc_setup_id',
    'sku',
    'barcode_id',
    'invent_dim_id',
    'source_system',
    'style_number',
    'active_colorways',
    'd365_color_code',
    'code_color',
    'rgb_hex',
    'size',
    'size_range',
    'sales_size_chart',
    'module_type',
    'product_class',
    'division_season',
    'original_season',
    'sprint',
    'product_sprint',
    'debut_date',
    'debut_year',
    'inactive_date',
    'vintage',
    'holiday',
    'planning_flag',
    'product_ownership',
    'shipping_vendor_id',
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
    'density',
    'product_quantity_uom',
    'designer',
    'model',
    'development_type',
    'garment_features',
    'sensory_friendly',
    'line_discount_group',
    'tax_item_group_id',
    'classification',
    'hts_code_duty_composition',
    'hero_image_aws_link',
    'website_url',
    'colorways_market_entry_date',
    'colorways_market_exit_date',
    'case_id',
    'factor',
    'style_level_leadtime_to_x_factory'
] %}

-- Output column order
{% set dim_product_columns = [
    'product_key',
    'product_id',
    'upc',
    'upc_setup_id',
    'sku',
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
    'reporting_category_group',
    'reporting_category_group_sort',
    'reporting_subcategory',
    'reporting_subcategory_sort',
    'loyalty_reporting_category',
    'loyalty_reporting_category_sort',
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
    'vintage',
    'holiday',
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
    'density',
    'product_quantity_uom',
    'designer',
    'model',
    'development_type',
    'garment_features',
    'sensory_friendly',
    'line_discount_group',
    'tax_item_group_id',
    'classification',
    'hts_code_duty_composition',
    'hero_image_aws_link',
    'website_url',
    'is_bc_upload_done',
    'colorways_market_entry_date',
    'colorways_market_exit_date',
    'case_id',
    'factor',
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

-- Reserved members (spec 3.4): -1 = product could not be resolved, 0 = no product by design
{% set reserved_member_rows = [
    {'key': unknown_member_key(), 'code': 'UNKNOWN', 'name': 'Unknown Product'},
    {'key': default_member_key(), 'code': 'NO_PRODUCT', 'name': 'Not Applicable'}
] %}

with business_products as (

    select
          snap_p.product_key
        , coalesce(stg.product_id, snap_p.product_id) as product_id
        {%- for c in type1_columns %}
        , case when stg.product_key is not null then stg.{{ c }} else snap_p.{{ c }} end as {{ c }}
        {%- endfor %}
        {%- for c in type2_columns %}
        , snap_p.{{ c }} as {{ c }}
        {%- endfor %}
        , cast(null as string) as d365_product_color
        , cast(null as string) as d365_product_color_size
        , cast(null as string) as code_color_style_name
        , cast(null as string) as original_season_fy
        , cast(null as string) as incoterm_code
        , cast(null as boolean) as is_bc_upload_done
        , coalesce(rc.reporting_category_group, 'Other') as reporting_category_group
        , coalesce(rc.reporting_category_group_sort, 9) as reporting_category_group_sort
        , coalesce(rc.reporting_subcategory, 'Other') as reporting_subcategory
        , coalesce(rc.reporting_subcategory_sort, 99) as reporting_subcategory_sort
        , coalesce(rc.loyalty_reporting_category, 'Other') as loyalty_reporting_category
        , coalesce(rc.loyalty_reporting_category_sort, 9) as loyalty_reporting_category_sort
        , snap_p.product_change_hash
        , snap_p.row_hash
        , snap_p.effective_start_datetime
        , snap_p.effective_end_datetime
        , snap_p.record_source_table
        , snap_p.etl_update_datetime
        , {{ scd2_version_number('snap_p.product_key', 'snap_p.effective_start_datetime') }} as version_number
        , {{ scd2_is_current_row('version_number', 'snap_p.effective_end_datetime') }} as is_current_row

    from {{ ref('silver_snapshot_dim_product') }} snap_p
    left join {{ ref('silver_stage_dim_product') }} stg
        on snap_p.product_key = stg.product_key
    left join {{ ref('ref_summary_class_rollup') }} rc
        on snap_p.summary_class = rc.summary_class

    where snap_p.product_id is not null  -- population rule, spec 3.5

),

reserved_members as (

    -- Hardcoded literals, never derived by hashing. Classification attributes read 'Reserved'
    -- (the DIM_VENDOR precedent); everything else is a typed NULL. product_id is never NULL,
    -- so the population rule above would not touch these rows either way.
    {%- for m in reserved_member_rows %}
    {{ 'union all' if not loop.first }}
    select
          cast('{{ m.key }}' as string) as product_key
        , cast('{{ m.code }}' as string) as product_id
        , cast('{{ m.code }}' as varchar(20)) as upc
        , cast(null as varchar(30)) as upc_setup_id
        , cast('{{ m.code }}' as string) as sku
        , cast(null as string) as barcode_id
        , cast(null as string) as invent_dim_id
        , cast('Manual Seed' as string) as source_system
        , cast('{{ m.code }}' as varchar(30)) as style_number
        , cast('{{ m.name }}' as varchar(100)) as style_name
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
        , cast('Reserved' as varchar(50)) as product_group
        , cast('Reserved' as varchar(50)) as product_sub_group
        , cast(null as varchar(50)) as product_set
        , cast(null as varchar(50)) as product_subset
        , cast(null as varchar(50)) as product_summary
        , cast('Reserved' as string) as summary_class
        , cast('Other' as string) as reporting_category_group
        , cast(9 as int) as reporting_category_group_sort
        , cast('Other' as string) as reporting_subcategory
        , cast(99 as int) as reporting_subcategory_sort
        , cast('Other' as string) as loyalty_reporting_category
        , cast(9 as int) as loyalty_reporting_category_sort
        , cast(null as int) as module_type
        , cast(null as string) as product_class
        , cast(null as varchar(100)) as classifier_3
        , cast(null as string) as code_color_style_name
        , cast('Reserved' as varchar(50)) as brand
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
        , cast(null as boolean) as vintage
        , cast(null as varchar(20)) as holiday
        , cast(null as varchar(30)) as plm_status
        , cast(null as string) as erp_status
        , cast('Reserved' as string) as dw_sku_status
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
        , cast(null as decimal(32,6)) as density
        , cast(null as varchar(10)) as product_quantity_uom
        , cast(null as varchar(100)) as designer
        , cast(null as varchar(100)) as model
        , cast(null as varchar(100)) as development_type
        , cast(null as varchar(100)) as garment_features
        , cast(null as varchar(100)) as sensory_friendly
        , cast(null as string) as line_discount_group
        , cast(null as varchar(20)) as tax_item_group_id
        , cast(null as varchar(20)) as classification
        , cast(null as string) as hts_code_duty_composition
        , cast(null as varchar(2083)) as hero_image_aws_link
        , cast(null as varchar(2083)) as website_url
        , cast(null as boolean) as is_bc_upload_done
        , cast(null as date) as colorways_market_entry_date
        , cast(null as date) as colorways_market_exit_date
        , cast(null as varchar(200)) as case_id
        , cast(null as int) as factor
        , cast(null as int) as style_level_leadtime_to_x_factory
        , cast('Reserved member - not derived from a hash.' as string) as product_change_hash
        , cast('RESERVED' as string) as row_hash
        , cast(null as timestamp) as effective_start_datetime
        , cast(null as timestamp) as effective_end_datetime
        , cast('Manual Seed' as string) as record_source_table
        , current_timestamp() as etl_update_datetime
        , cast(null as int) as retirement_year
        , cast(1 as int) as version_number
        , cast(1 as int) as is_current_row
    {%- endfor %}

)

select
    {%- for c in dim_product_columns %}
    {{ ', ' if not loop.first }}{{ c }}
    {%- endfor %}
from business_products

union all

select
    {%- for c in dim_product_columns %}
    {{ ', ' if not loop.first }}{{ c }}
    {%- endfor %}
from reserved_members
