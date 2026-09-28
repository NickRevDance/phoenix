{{ config(materialized = 'table') }}

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