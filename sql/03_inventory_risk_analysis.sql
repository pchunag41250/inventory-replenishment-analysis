-- ============================================================
-- Inventory Operations Project
-- 03_inventory_risk_analysis.sql
-- Inventory Risk and Open Purchase Orders
--
-- Goal:
--   Build a one-row-per-item inventory snapshot that shows
--   which items need replenishment follow-up and whether
--   there are open purchase orders with quantities still due.
--
-- Business question:
--   As of 2016-05-31, which items are at or below their reorder
--   levels? How many units are still outstanding on purchase
--   orders, and when is the earliest expected delivery?
--
-- Relationship to previous scripts:
--   01_structured_data_audit.sql
--       Checks source data quality and table relationships.
--   02_create_clean_tables.sql
--       Creates and validates the typed tables used below.
--
-- Inputs:
--   clean_stock_items
--       Item names, master supplier, and package conversion factors.
--   clean_stock_item_holdings
--       Quantity on hand, reorder level, and target stock level.
--   clean_suppliers
--       Supplier names for the item master and purchase orders.
--   clean_purchase_orders
--       Purchase order supplier, finalized status, and expected date.
--   clean_purchase_order_lines
--       Item, package type, ordered and received quantities,
--       and line finalized status.
--
-- Workflow:
--   1.1 Identify items at or below their reorder level.
--       Flag an item when QuantityOnHand <= ReorderLevel.
--       Calculate the gap to target before considering open orders.
--
--   2.1 Inspect open purchase order lines.
--       Include a line when both the order and the line are
--       unfinalized and OrderedOuters > ReceivedOuters.
--       Calculate remaining outer packages and convert to units
--       when the package type matches the item master's outer
--       package type and QuantityPerOuter is positive.
--
--   3.1 Summarize open purchases by StockItemID.
--       Count distinct open orders, sum outstanding units when
--       all lines can be converted, and take the earliest
--       expected delivery date across qualifying lines.
--
--   4.1 Join the purchase summary to the inventory snapshot.
--       Use LEFT JOIN to retain items with no open purchases.
--       The full output has one row per item. Filter
--       at_reorder_level = 1 to obtain the watchlist.
--
--   5.1 Validate the result.
--       Check item counts, duplicates, reorder flags, and
--       open purchase coverage. Reconcile the watchlist
--       quantities and delivery dates with the line details.
--
--   5.2 Export the full result from 4.1.
--       Output: inventory_risk_snapshot_2016-05-31.csv
--       Use the item-level result, not the one-row validation
--       summary, as the reporting input.
--
-- Metric definitions:
--   gap_to_target
--       TargetStockLevel - QuantityOnHand for watchlist items.
--       This is the gap before open purchases are considered.
--
--   remaining_outers
--       OrderedOuters - ReceivedOuters at the purchase-line level.
--
--   remaining_units
--       remaining_outers * QuantityPerOuter when conversion is
--       supported. Otherwise NULL.
--
--   open_units
--       Total outstanding units per item. Show 0 when no
--       qualifying open line exists. Keep NULL when any open
--       line cannot be converted, so a partial sum is not
--       presented as the full quantity.
--
--   earliest_expected_delivery_date
--       Earliest planned date among the item's open lines.
--       This is not necessarily the date all units will arrive.
--
--   days_until_expected_delivery
--       Earliest expected delivery date minus the snapshot date.
--       Keep NULL when there is no qualifying open purchase.
--
-- Validation results for this snapshot:
--   227 distinct items, 0 duplicate rows.
--   9 qualifying open lines across 2 purchase orders and 9 items.
--   2 items at or below their reorder level, both with open purchases.
--   Item 86: 3 on hand, reorder level 5, 45,216 units outstanding.
--   Item 184: 38 on hand, reorder level 50, 41,850 units outstanding.
--   Both items: earliest expected delivery 2016-06-20,
--   20 calendar days after the snapshot date.
--
-- Interpretation and limitations:
--   The item master supplier can differ from the supplier on a
--   particular purchase order. Use the line details for the latter.
--   Outstanding units are not yet available for use. Package
--   conversion uses the factor in the imported item master.
--   Expected delivery is a plan, not evidence of actual receipt.
--   This script analyzes one imported snapshot. Changing the
--   date alone does not reconstruct historical inventory or
--   purchase order status.
--
-- Next step:
--   04_inventory_coverage_analysis.sql uses recent observed sales
--   outflow to estimate whether stock can last until delivery.
-- ============================================================

USE inventory_ops;

-- 1.1 Identify items at or below their reorder level.
select 
	s.StockItemID, 
    s.StockItemName, 
    h.QuantityOnHand, 
    h.ReorderLevel, 
    h.TargetStockLevel, 
    h.TargetStockLevel - h.QuantityOnHand as gap_to_targets
from clean_stock_items  s 
join clean_stock_item_holdings h 
	on s.StockItemID = h.StockItemID
join clean_suppliers as sp 
	on s.SupplierID = sp.SupplierID
where h.QuantityOnHand <= h.ReorderLevel
order by gap_to_targets desc, s.StockItemID; 


-- 2.1 Inspect open purchase order lines with unreceived quantities.
SELECT
    l.PurchaseOrderLineID,
    p.PurchaseOrderID,
    l.StockItemID,
    s.StockItemName,
    sp.SupplierName,
    l.OrderedOuters,
    l.ReceivedOuters,
    l.OrderedOuters - l.ReceivedOuters AS remaining_outers,
    CASE
        WHEN l.PackageTypeID = s.OuterPackageID
            AND s.QuantityPerOuter > 0
        THEN (l.OrderedOuters - l.ReceivedOuters) * s.QuantityPerOuter
        ELSE NULL
    END AS remaining_units,
    p.ExpectedDeliveryDate,
    CASE
        WHEN h.StockItemID IS NULL THEN NULL
        WHEN h.QuantityOnHand <= h.ReorderLevel THEN 1
        ELSE 0
    END AS is_item_from_step_1_1
FROM clean_purchase_order_lines AS l
JOIN clean_purchase_orders AS p
    ON l.PurchaseOrderID = p.PurchaseOrderID
JOIN clean_stock_items AS s
    ON l.StockItemID = s.StockItemID
JOIN clean_suppliers AS sp
    ON p.SupplierID = sp.SupplierID
LEFT JOIN clean_stock_item_holdings AS h
    ON l.StockItemID = h.StockItemID
WHERE p.IsOrderFinalized = 0
    AND l.IsOrderLineFinalized = 0
    AND l.OrderedOuters > l.ReceivedOuters
ORDER BY
    is_item_from_step_1_1 DESC,
    p.ExpectedDeliveryDate,
    l.PurchaseOrderLineID;

-- 3.1 Summarize open purchase orders by stock item.

with open_lines as (
	select 
		l.StockItemID, 
        l.PurchaseOrderID, 
        p.ExpectedDeliveryDate, 
        case 
			when l.PackageTypeID = s.OuterPackageID
				and s.QuantityPerOuter > 0 
			then (l.OrderedOuters - l.ReceivedOuters) * s.QuantityPerOuter 
            end as remaining_units
    from clean_purchase_order_lines l 
    join clean_purchase_orders as p 
		on l.PurchaseOrderID = p.PurchaseOrderID
	join clean_stock_items as s 
		on s.stockitemID = l.stockitemID
	where p.IsOrderFinalized = 0 
		and l.IsOrderLineFinalized = 0 
        and l.OrderedOuters > l.ReceivedOuters
)

select 
	StockItemID, 
    count(*) open_line_count, 
    count(distinct PurchaseOrderID) as open_order_count, 
    count(*) - count(remaining_units) as unconvertible_line_count,
    case 
		when count(*) = count(remaining_units)
        then sum(remaining_units)
	end as open_units, 
    min(ExpectedDeliveryDate) as earlist_expected_delivery_date
from open_lines
group by StockItemID 
order by StockItemID; 

-- 4.1 Combine inventory and open purchase orders by stock item.

with open_lines as(
	select 
		l.StockItemID, 
        l.PurchaseOrderID, 
        p.ExpectedDeliveryDate,
        case 
			when l.PackageTypeID = s.OuterPackageID
				and s.QuantityPerOuter > 0 
			then (l.OrderedOuters - l.ReceivedOuters) * s.QuantityPerOuter 
            end as remaining_units
    from clean_purchase_order_lines l 
    join clean_purchase_orders p 
		on l.PurchaseOrderID = p.PurchaseOrderID
	join clean_stock_items s 
		on s.stockitemID = l.stockitemID
	where p.IsOrderFinalized = 0 
		and l.IsOrderLineFinalized = 0 
        and l.OrderedOuters > l.ReceivedOuters
), 
open_purchase_by_item as (
	select 
		StockItemID, 
        count(distinct PurchaseOrderID) as open_order_count, 
        count(*) - count(remaining_units) as unconvertible_line_count,
        case 
			when count(*) = count(remaining_units)
            then sum(remaining_units)
            end as open_units, 
			min(ExpectedDeliveryDate) as earliest_expected_delivery_date
    from open_lines
    group by StockItemID
)

select 
	date '2016-05-31' as snapshot_date, 
    s.stockitemID, 
    s.StockItemName, 
    sp.SupplierName, 
    h.QuantityOnHand, 
    h.ReorderLevel, 
    h.TargetStockLevel, 
    h.QuantityOnHand <= h.ReorderLevel as at_reorder_level, 
    coalesce(p.open_order_count, 0 ) as open_order_count, 
    case 
		when p.stockitemID is null then 'no_open_purchase'
        when p.unconvertible_line_count > 0 then 'check_package_conversion'
        else 'awaiting_receipt'
	end as purchase_status, 
    CASE
    WHEN p.StockItemID IS NULL THEN 0
    ELSE p.open_units
	END AS open_units,
	p.earliest_expected_delivery_date
from clean_stock_items as s 
join clean_stock_item_holdings h 
	on h.StockItemID = s.StockItemID
join clean_suppliers sp 
	on s.SupplierID = sp.SupplierID
left join open_purchase_by_item p 
	on s.stockitemID = p.stockitemID
order by at_reorder_level desc, s.StockItemID; 


-- 5.1 
with open_lines as(
	select 
		l.StockItemID, 
        l.PurchaseOrderID, 
        p.ExpectedDeliveryDate,
        case 
			when l.PackageTypeID = s.OuterPackageID
				and s.QuantityPerOuter > 0 
			then (l.OrderedOuters - l.ReceivedOuters) * s.QuantityPerOuter 
            end as remaining_units
    from clean_purchase_order_lines l 
    join clean_purchase_orders p 
		on l.PurchaseOrderID = p.PurchaseOrderID
	join clean_stock_items s 
		on s.stockitemID = l.stockitemID
	where p.IsOrderFinalized = 0 
		and l.IsOrderLineFinalized = 0 
        and l.OrderedOuters > l.ReceivedOuters
), 
open_purchase_by_item as (
	select 
		StockItemID, 
        count(distinct PurchaseOrderID) as open_order_count, 
        count(*) - count(remaining_units) as unconvertible_line_count,
        case 
			when count(*) = count(remaining_units)
            then sum(remaining_units)
            end as open_units, 
			min(ExpectedDeliveryDate) as earliest_expected_delivery_date
    from open_lines
    group by StockItemID
), 
inventory_risk as(
	select
		s.StockItemID, 
        (h.QuantityOnHand <= h.ReorderLevel) at_reorder_level, 
        coalesce(p.open_order_count, 0) as open_order_count
    from clean_stock_items s 
    join clean_stock_item_holdings h 
		on s.StockItemID = h.StockItemID
	join clean_suppliers sp 
		on sp.SupplierID = s.SupplierID
	left join open_purchase_by_item as p 
		on s.StockItemID = p.StockItemID
)

select 
	count(*) as total_rows, 
    count(distinct StockItemID) as distinct_items, 
    count(*) - count(distinct StockItemID) as duplicate_rows, 
    sum(at_reorder_level = 1 ) as order_items, 
    sum(open_order_count > 0) as items_with_open_purchases,
    sum(at_reorder_level = 1 and open_order_count > 0) as reorder_items_with_open_purchases
from inventory_risk; 