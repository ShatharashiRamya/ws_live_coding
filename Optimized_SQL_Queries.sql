-- ------------------------------------QUERY 1-------------------------------------------------
-- CTE 1: aggregate all metrics per customer in a SINGLE join + GROUP BY
WITH customer_metrics AS (
    SELECT
        o.customer_id,
        ROUND(
            SUM(oi.quantity * oi.unit_price * (1.0 - oi.discount_pct / 100.0)),
            2
        )                              AS lifetime_value,
        COUNT(DISTINCT o.order_id)      AS total_orders,
        MAX(o.order_date)               AS last_order_date
    FROM orders o
    INNER JOIN order_items oi ON o.order_id = oi.order_id
    WHERE o.status NOT IN ('cancelled', 'returned')
    GROUP BY o.customer_id
),

-- CTE 2: join customers → metrics, then rank within each region
region_ranked AS (
    SELECT
        c.customer_id,
        c.name,
        c.region,
        c.tier,
        COALESCE(cm.lifetime_value,  0)  AS lifetime_value,
        COALESCE(cm.total_orders,    0)  AS total_orders,
        cm.last_order_date,
        ROW_NUMBER() OVER (
            PARTITION BY c.region
            ORDER BY COALESCE(cm.lifetime_value, 0) DESC
        ) AS rn
    FROM customers c
    LEFT JOIN customer_metrics cm ON c.customer_id = cm.customer_id
)

-- Final: filter top 3 per region
SELECT
    customer_id,
    name,
    region,
    tier,
    lifetime_value,
    total_orders,
    last_order_date
FROM region_ranked
WHERE rn <= 3
ORDER BY region, lifetime_value DESC;

---------------------------------------   QUERY 2 -----------------------------------------------
-- CTE: aggregate revenue once per region/year/month in a SINGLE pass
WITH monthly_revenue AS (
    SELECT
        o.region,
        CAST(strftime('%Y', o.order_date) AS INTEGER)  AS yr,
        CAST(strftime('%m', o.order_date) AS INTEGER)  AS mo,
        ROUND(SUM(p.amount), 2)                          AS monthly_rev
    FROM orders o
    INNER JOIN payments p ON o.order_id = p.order_id
    WHERE p.status = 'Success'
    GROUP BY
        o.region,
        strftime('%Y', o.order_date),
        strftime('%m', o.order_date)
)

SELECT
    region,
    yr,
    mo,
    monthly_rev,

    -- previous month's revenue via LAG() — no self-join 
    LAG(monthly_rev) OVER (
        PARTITION BY region
        ORDER BY    yr, mo
    ) AS prev_month_rev,

    -- MoM growth % derived from LAG value
    ROUND(
        (
            monthly_rev
            - LAG(monthly_rev) OVER (
                PARTITION BY region ORDER BY yr, mo
              )
        )
        / NULLIF(
            LAG(monthly_rev) OVER (
                PARTITION BY region ORDER BY yr, mo
            ), 0
          )
        * 100,
        2
    )   AS mom_growth_pct,

    -- cumulative running total per region — no correlated subquery
    ROUND(
        SUM(monthly_rev) OVER (
            PARTITION BY region
            ORDER BY    yr, mo
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ),
        2
    )  AS running_total

FROM  monthly_revenue
ORDER BY region, yr, mo;


