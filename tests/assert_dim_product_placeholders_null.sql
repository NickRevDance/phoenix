-- The six placeholder columns have no source and must be NULL on every row (spec 3.6, EDW-118).
select product_key, version_number
from {{ ref('dim_product') }}
where d365_product_color is not null
   or d365_product_color_size is not null
   or code_color_style_name is not null
   or original_season_fy is not null
   or incoterm_code is not null
   or is_bc_upload_done is not null
