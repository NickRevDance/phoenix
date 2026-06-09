SELECT 
    * 
FROM 
    {{source('dwhvisualnext','centric_product')}}
WHERE 
    D365ProductSetup = 'Completed' 
    AND IsCurrent