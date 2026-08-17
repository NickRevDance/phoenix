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
    , row_number() over (
        partition by product_key
        order by effective_start_datetime desc
    ) as version_number
    , case when version_number = 1 then 1 else 0 end as is_current_row
FROM
    {{ref("silver_snapshot_dim_product")}} snap_p