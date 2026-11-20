-- Inventory coverage and replenishment | MySQL 8
-- Requires the raw transaction import and the clean tables from script 02.
-- Snapshot: 2016-05-31. Type 10 outflow over the preceding 30 calendar days.
-- Shortfalls are scenario estimates, not observed stockouts.
-- Run 01 and 02 for source checks and cleaning before exporting.
USE inventory_ops;

-- 4.1 Action export. Save this result as inventory_action_list.csv.
with sales_last_30_days as (
    select
        cast(trim(StockItemID) as unsigned) as StockItemID,
        -cast(trim(Quantity) as decimal(18,3)) as units_sold
    from raw_stock_item_transactions
    where trim(TransactionTypeID) = '10'
        and trim(TransactionOccurredWhen) >= '2016-05-02 00:00:00'
        and trim(TransactionOccurredWhen) < '2016-06-01 00:00:00'
),
demand_by_item AS(
    select
        StockItemID,
        count(*) as sales_rows_30d,
        sum(units_sold) as units_sold_30d,
        sum(units_sold) / 30 as avg_daily_units_sold
    from sales_last_30_days
    group by StockItemID
),
open_purchase_by_item as(
    select
        l.StockItemID,
        count(distinct l.PurchaseOrderID) as open_order_count,
        min(p.ExpectedDeliveryDate) as earliest_delivery_date
    from clean_purchase_order_lines l
    join clean_purchase_orders p
        on p.PurchaseOrderID = l.PurchaseOrderID
    where l.IsOrderLineFinalized = 0
        and l.OrderedOuters > l.ReceivedOuters
        and p.IsOrderFinalized = 0
    group by l.StockItemID
),
coverage as (
    select
        date '2016-05-31' as snapshot_date,
        h.StockItemID,
        s.StockItemName,
        h.QuantityOnHand,
        h.ReorderLevel,
        h.QuantityOnHand <= h.ReorderLevel at_reorder_level,
        coalesce(d.avg_daily_units_sold, 0) as avg_daily_units_sold,
        h.QuantityOnHand / nullif(d.avg_daily_units_sold, 0) as days_of_cover,
        coalesce(p.open_order_count, 0) as open_order_count,
        p.earliest_delivery_date,
        datediff(p.earliest_delivery_date, date '2016-05-31') as days_until_receipt
    from clean_stock_item_holdings h
    join clean_stock_items s
        on h.StockItemID = s.StockItemID
    left join demand_by_item  as d
        on d.StockItemID = h.StockItemID
    left join open_purchase_by_item as p
        on p.StockItemID = h.StockItemID
),
receipt_risk_by_item as (
select
    snapshot_date,
    StockItemID,
    StockItemName,
    QuantityOnHand,
    ReorderLevel,
    at_reorder_level,
    avg_daily_units_sold,
    round(days_of_cover, 2 ) as estimated_days_of_cover,
    open_order_count,
    earliest_delivery_date,
    days_until_receipt,
    CASE
        WHEN open_order_count = 0 THEN 'no_open_purchase'
        WHEN days_until_receipt IS NULL THEN 'missing_expected_date'
        WHEN days_until_receipt < 0 THEN 'past_due_eta'
        WHEN days_of_cover IS NULL THEN 'no_recent_sales'
        WHEN days_of_cover < days_until_receipt THEN 'stockout_risk'
        ELSE 'covered_until_eta'
    END AS receipt_risk,
    CASE
        WHEN days_until_receipt >= 0 AND avg_daily_units_sold > 0
        THEN ROUND(
            GREATEST(0, avg_daily_units_sold * days_until_receipt - QuantityOnHand),
            2
        )
    END AS estimated_shortfall_units
from coverage),
no_open_purchase_risk AS (
    SELECT
        c.StockItemID,
        s.LeadTimeDays,
        CASE
            WHEN c.at_reorder_level = 1 THEN 'review_reorder_now'
            WHEN s.LeadTimeDays IS NULL OR s.LeadTimeDays <= 0
                THEN 'check_lead_time'
            WHEN c.days_of_cover IS NULL THEN 'no_recent_sales'
            WHEN c.days_of_cover < s.LeadTimeDays THEN 'review_early_reorder'
            ELSE 'covered_through_lead_time'
        END AS replenishment_action,
        CASE
            WHEN s.LeadTimeDays > 0 AND c.avg_daily_units_sold > 0
            THEN ROUND(
                GREATEST(0, c.avg_daily_units_sold * s.LeadTimeDays
                            - c.QuantityOnHand),
                2
            )
        END AS estimated_lead_time_shortfall_units
    FROM coverage AS c
    JOIN clean_stock_items AS s
        ON s.StockItemID = c.StockItemID
    WHERE c.open_order_count = 0
),
-- Combine both risk assessments into one action list.
final_action_list AS (
    SELECT
        r.*,
        n.LeadTimeDays,
        n.replenishment_action,
        n.estimated_lead_time_shortfall_units,
        CASE
            WHEN r.receipt_risk = 'stockout_risk' THEN 'expedite_existing_po'
            WHEN r.receipt_risk = 'past_due_eta' THEN 'follow_up_past_due_po'
            WHEN r.receipt_risk = 'missing_expected_date' THEN 'confirm_expected_date'
            WHEN r.receipt_risk = 'covered_until_eta' THEN 'monitor'
            WHEN n.replenishment_action = 'covered_through_lead_time' THEN 'monitor'
            WHEN n.replenishment_action IN (
                'review_reorder_now', 'review_early_reorder', 'check_lead_time'
            ) THEN n.replenishment_action
            WHEN r.receipt_risk = 'no_recent_sales'
              OR n.replenishment_action = 'no_recent_sales' THEN 'review_sales_history'
            ELSE 'review_data'
        END AS recommended_action
    FROM receipt_risk_by_item AS r
    LEFT JOIN no_open_purchase_risk AS n
        ON n.StockItemID = r.StockItemID
)
SELECT *
FROM final_action_list
ORDER BY
    CASE WHEN recommended_action = 'monitor' THEN 1 ELSE 0 END,
    estimated_shortfall_units DESC,
    estimated_lead_time_shortfall_units DESC,
    StockItemID;

-- 4.3 Scenario export.
-- Save this result as po_expedite_scenarios.csv.
with sales_last_30_days as (
    select
        cast(trim(StockItemID) as unsigned) as StockItemID,
        -cast(trim(Quantity) as decimal(18,3)) as units_sold
    from raw_stock_item_transactions
    where trim(TransactionTypeID) = '10'
        and trim(TransactionOccurredWhen) >= '2016-05-02 00:00:00'
        and trim(TransactionOccurredWhen) < '2016-06-01 00:00:00'
),
demand_by_item AS(
    select
        StockItemID,
        count(*) as sales_rows_30d,
        sum(units_sold) as units_sold_30d,
        sum(units_sold) / 30 as avg_daily_units_sold
    from sales_last_30_days
    group by StockItemID
),
open_purchase_by_item as(
    select
        l.StockItemID,
        count(distinct l.PurchaseOrderID) as open_order_count,
        min(p.ExpectedDeliveryDate) as earliest_delivery_date
    from clean_purchase_order_lines l
    join clean_purchase_orders p
        on p.PurchaseOrderID = l.PurchaseOrderID
    where l.IsOrderLineFinalized = 0
        and l.OrderedOuters > l.ReceivedOuters
        and p.IsOrderFinalized = 0
    group by l.StockItemID
),
coverage as (
    select
        date '2016-05-31' as snapshot_date,
        h.StockItemID,
        s.StockItemName,
        h.QuantityOnHand,
        h.ReorderLevel,
        h.QuantityOnHand <= h.ReorderLevel at_reorder_level,
        coalesce(d.avg_daily_units_sold, 0) as avg_daily_units_sold,
        h.QuantityOnHand / nullif(d.avg_daily_units_sold, 0) as days_of_cover,
        coalesce(p.open_order_count, 0) as open_order_count,
        p.earliest_delivery_date,
        datediff(p.earliest_delivery_date, date '2016-05-31') as days_until_receipt
    from clean_stock_item_holdings h
    join clean_stock_items s
        on h.StockItemID = s.StockItemID
    left join demand_by_item  as d
        on d.StockItemID = h.StockItemID
    left join open_purchase_by_item as p
        on p.StockItemID = h.StockItemID
),
receipt_risk_by_item as (
select
    snapshot_date,
    StockItemID,
    StockItemName,
    QuantityOnHand,
    ReorderLevel,
    at_reorder_level,
    avg_daily_units_sold,
    round(days_of_cover, 2 ) as estimated_days_of_cover,
    open_order_count,
    earliest_delivery_date,
    days_until_receipt,
    CASE
        WHEN open_order_count = 0 THEN 'no_open_purchase'
        WHEN days_until_receipt IS NULL THEN 'missing_expected_date'
        WHEN days_until_receipt < 0 THEN 'past_due_eta'
        WHEN days_of_cover IS NULL THEN 'no_recent_sales'
        WHEN days_of_cover < days_until_receipt THEN 'stockout_risk'
        ELSE 'covered_until_eta'
    END AS receipt_risk,
    CASE
        WHEN days_until_receipt >= 0 AND avg_daily_units_sold > 0
        THEN ROUND(
            GREATEST(0, avg_daily_units_sold * days_until_receipt - QuantityOnHand),
            2
        )
    END AS estimated_shortfall_units
from coverage),
no_open_purchase_risk AS (
    SELECT
        c.StockItemID,
        s.LeadTimeDays,
        CASE
            WHEN c.at_reorder_level = 1 THEN 'review_reorder_now'
            WHEN s.LeadTimeDays IS NULL OR s.LeadTimeDays <= 0
                THEN 'check_lead_time'
            WHEN c.days_of_cover IS NULL THEN 'no_recent_sales'
            WHEN c.days_of_cover < s.LeadTimeDays THEN 'review_early_reorder'
            ELSE 'covered_through_lead_time'
        END AS replenishment_action,
        CASE
            WHEN s.LeadTimeDays > 0 AND c.avg_daily_units_sold > 0
            THEN ROUND(
                GREATEST(0, c.avg_daily_units_sold * s.LeadTimeDays
                            - c.QuantityOnHand),
                2
            )
        END AS estimated_lead_time_shortfall_units
    FROM coverage AS c
    JOIN clean_stock_items AS s
        ON s.StockItemID = c.StockItemID
    WHERE c.open_order_count = 0
),
-- Combine both risk assessments into one action list.
final_action_list AS (
    SELECT
        r.*,
        n.LeadTimeDays,
        n.replenishment_action,
        n.estimated_lead_time_shortfall_units,
        CASE
            WHEN r.receipt_risk = 'stockout_risk' THEN 'expedite_existing_po'
            WHEN r.receipt_risk = 'past_due_eta' THEN 'follow_up_past_due_po'
            WHEN r.receipt_risk = 'missing_expected_date' THEN 'confirm_expected_date'
            WHEN r.receipt_risk = 'covered_until_eta' THEN 'monitor'
            WHEN n.replenishment_action = 'covered_through_lead_time' THEN 'monitor'
            WHEN n.replenishment_action IN (
                'review_reorder_now', 'review_early_reorder', 'check_lead_time'
            ) THEN n.replenishment_action
            WHEN r.receipt_risk = 'no_recent_sales'
              OR n.replenishment_action = 'no_recent_sales' THEN 'review_sales_history'
            ELSE 'review_data'
        END AS recommended_action
    FROM receipt_risk_by_item AS r
    LEFT JOIN no_open_purchase_risk AS n
        ON n.StockItemID = r.StockItemID
),
open_po_items AS (
    SELECT DISTINCT
        l.StockItemID,
        p.PurchaseOrderID,
        p.ExpectedDeliveryDate
    FROM clean_purchase_order_lines AS l
    JOIN clean_purchase_orders AS p
        ON p.PurchaseOrderID = l.PurchaseOrderID
    WHERE p.IsOrderFinalized = 0
      AND l.IsOrderLineFinalized = 0
      AND l.OrderedOuters > l.ReceivedOuters
),
scenario_candidates AS (
    SELECT *, earliest_delivery_date AS original_eta,
           days_until_receipt AS original_wait_days
    FROM final_action_list
    WHERE recommended_action = 'expedite_existing_po'
),
po_scenarios AS (
    SELECT
        p.PurchaseOrderID,
        a.StockItemID,
        a.StockItemName,
        a.snapshot_date,
        a.QuantityOnHand,
        a.avg_daily_units_sold,
        a.original_eta,
        a.original_wait_days,
        GREATEST(
            a.snapshot_date,
            DATE_SUB(a.original_eta, INTERVAL 7 DAY)
        ) AS expedited_eta,
        GREATEST(0, a.original_wait_days - 7) AS expedited_wait_days
    FROM scenario_candidates AS a
    JOIN open_po_items AS p
        ON p.StockItemID = a.StockItemID
       AND p.ExpectedDeliveryDate = a.original_eta
),
-- Estimate the inventory shortfall before receipt in each scenario.
scenario_results AS (
    SELECT
        p.*,
        GREATEST(
            0,
            p.avg_daily_units_sold * p.original_wait_days - p.QuantityOnHand
        ) AS original_shortfall_units,
        GREATEST(
            0,
            p.avg_daily_units_sold * p.expedited_wait_days - p.QuantityOnHand
        ) AS expedited_shortfall_units
    FROM po_scenarios AS p
)
SELECT
    PurchaseOrderID,
    StockItemID,
    StockItemName,
    snapshot_date,
    QuantityOnHand,
    avg_daily_units_sold,
    original_eta,
    original_wait_days,
    expedited_eta,
    expedited_wait_days,
    ROUND(original_shortfall_units, 2) AS original_shortfall_units,
    ROUND(expedited_shortfall_units, 2) AS expedited_shortfall_units,
    ROUND(original_shortfall_units - expedited_shortfall_units, 2)
        AS shortfall_reduction_units
FROM scenario_results
ORDER BY PurchaseOrderID, expedited_shortfall_units DESC, StockItemID;
