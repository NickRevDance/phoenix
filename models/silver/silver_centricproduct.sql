select
    *
FROM
    {{ref("bronze_centricproduct")}}
WHERE
    D365ProductSetup = 'Completed' 
    AND IsCurrent