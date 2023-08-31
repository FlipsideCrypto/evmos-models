{{ config(
    materialized = 'table'
) }}

SELECT
    blockchain,
    creator,
    address,
    label_type,
    label_subtype,
    project_name,
    address_name
FROM
    {{ source(
        'crosschain',
        'dim_labels'
    ) }}
WHERE
    blockchain = 'evmos'
