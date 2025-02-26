{{ config(
    materialized = 'incremental',
    full_refresh = false
) }}

WITH rel_blocks AS (

    SELECT
        block_id,
        block_timestamp
    FROM
        {{ ref('silver__blocks') }}
    WHERE
        block_timestamp < DATEADD(
            HOUR,
            -48,
            SYSDATE()
        )

{% if is_incremental() %}
AND (
    block_timestamp >= DATEADD(
        HOUR,
        -96,(
            SELECT
                MAX(
                    max_block_timestamp
                )
            FROM
                {{ this }}
        )
    )
    OR ({% if var('OBSERV_FULL_TEST') %}
        block_id >= 0
    {% else %}
        block_id >= (
    SELECT
        MIN(VALUE) - 1
    FROM
        (
    SELECT
        blocks_impacted_array
    FROM
        {{ this }}
        qualify ROW_NUMBER() over (
    ORDER BY
        test_timestamp DESC) = 1), LATERAL FLATTEN(input => blocks_impacted_array))
    {% endif %})
)
{% endif %}
),
bronze AS (
    SELECT
        A.block_number AS block_id,
        b.block_timestamp,
        COALESCE(
            t.value :tx_result :tx_id,
            t.value :hash
        ) :: STRING AS tx_id
    FROM
        {% if var('OBSERV_FULL_TEST') %}
            {{ ref('bronze__streamline_FR_tendermint_transactions') }}
        {% else %}
            {{ ref('bronze__streamline_tendermint_transactions') }}
        {% endif %}

        A
        JOIN rel_blocks b
        ON A.block_number = b.block_id
        JOIN TABLE(FLATTEN(DATA :result :txs)) t {# {% if is_incremental() %}
    WHERE
        A._inserted_timestamp >= CURRENT_DATE - 14
        OR {% if var('OBSERV_FULL_TEST') %}
            1 = 1
        {% else %}
            (
                SELECT
                    MIN(VALUE) - 1
                FROM
                    (
                        SELECT
                            blocks_impacted_array
                        FROM
                            {{ this }}
                            qualify ROW_NUMBER() over (
                                ORDER BY
                                    test_timestamp DESC
                            ) = 1
                    ),
                    LATERAL FLATTEN(
                        input => blocks_impacted_array
                    )
            ) IS NOT NULL
        {% endif %}
    {% endif %}

    #}
    qualify(ROW_NUMBER() over(PARTITION BY A.block_number, tx_id
    ORDER BY
        A._inserted_timestamp DESC) = 1)
),
bronze_count AS (
    SELECT
        block_id,
        block_timestamp,
        COUNT(
            DISTINCT tx_id
        ) AS num_txs
    FROM
        bronze
    GROUP BY
        block_id,
        block_timestamp
),
bronze_api AS (
    SELECT
        block_id,
        block_timestamp,
        num_txs
    FROM
        {{ ref('silver__blockchain') }}
    WHERE
        block_id > 13066416
        AND block_timestamp BETWEEN (
            SELECT
                MIN(block_timestamp)
            FROM
                rel_blocks
        )
        AND (
            SELECT
                MAX(block_timestamp)
            FROM
                rel_blocks
        )
)
SELECT
    'transactions' AS test_name,
    MIN(
        A.block_id
    ) AS min_block,
    MAX(
        A.block_id
    ) AS max_block,
    MIN(
        A.block_timestamp
    ) AS min_block_timestamp,
    MAX(
        A.block_timestamp
    ) AS max_block_timestamp,
    COUNT(1) AS blocks_tested,
    SUM(
        CASE
            WHEN COALESCE(
                b.num_txs,
                0
            ) - A.num_txs < -3 THEN 1
            ELSE 0
        END
    ) AS blocks_impacted_count,
    ARRAY_AGG(
        CASE
            WHEN COALESCE(
                b.num_txs,
                0
            ) - A.num_txs < -3 THEN A.block_id
        END
    ) within GROUP (
        ORDER BY
            A.block_id
    ) AS blocks_impacted_array,
    SUM(
        ABS(
            COALESCE(
                b.num_txs,
                0
            ) - A.num_txs
        )
    ) AS transactions_impacted_count,
    ARRAY_AGG(
        CASE
            WHEN COALESCE(
                b.num_txs,
                0
            ) - A.num_txs < -3 THEN OBJECT_CONSTRUCT(
                'block',
                A.block_id,
                'block_timestamp',
                A.block_timestamp,
                'diff',
                COALESCE(
                    b.num_txs,
                    0
                ) - A.num_txs,
                'blockchain_num_txs',
                A.num_txs,
                'bronze_num_txs',
                COALESCE(
                    b.num_txs,
                    0
                )
            )
        END
    ) within GROUP(
        ORDER BY
            A.block_id
    ) AS test_failure_details,
    SYSDATE() AS test_timestamp
FROM
    bronze_api A
    LEFT JOIN bronze_count b
    ON A.block_id = b.block_id
