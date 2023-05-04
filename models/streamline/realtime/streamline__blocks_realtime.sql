{{ config (
    materialized = "view",
    post_hook = if_data_call_function(
        func = "{{this.schema}}.udf_json_rpc(object_construct('sql_source', '{{this.identifier}}', 'external_table', 'blocks', 'exploded_key','data', 'method', 'eth_getBlockByNumber', 'producer_batch_size',10000, 'producer_limit_size', 1000000, 'worker_batch_size',1000, 'producer_batch_chunks_size', 10000))",
        target = "{{this.schema}}.{{this.identifier}}"
    )
) }}

WITH last_3_days AS (
    {% if var('STREAMLINE_RUN_HISTORY')%}
        SELECT 
            0 AS block_number
    {% else %}
        SELECT
            MAX(block_number) - 100000 AS block_number --aprox 3 days
        FROM
            {{ ref("streamline__blocks") }}
    {% endif %}
),
tbl AS (
    SELECT
        block_number,
        block_number_hex
    FROM
        {{ ref("streamline__blocks") }}
    WHERE
        (
            block_number >= (
                SELECT
                    block_number
                FROM
                    last_3_days
            )
        )
        AND block_number IS NOT NULL
)
SELECT
    block_number,
    'eth_getBlockByNumber' AS method,
    CONCAT(
        block_number_hex,
        '_-_',
        'false'
    ) AS params
FROM
    tbl