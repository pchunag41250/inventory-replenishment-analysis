-- ============================================================
-- Inventory Operations Project
-- Structured Data Audit
--
-- Goal:
--   Understand and validate the source data used to identify
--   inventory and purchasing risks.
--
-- Analysis reference date: 2016-05-31
--
-- Scope:
--   1. raw_stock_items
--   2. raw_stock_item_holdings
--   3. raw_suppliers
--   4. raw_purchase_orders
--   5. raw_purchase_order_lines
--
-- Audit sections:
--   1. Database and table overview
--   2. Table structure and selected field previews
--   3. Table-level data quality checks

-- ============================================================

USE inventory_ops;

-- ============================================================
-- SECTION 1: DATABASE AND TABLE OVERVIEW
-- ============================================================

-- 1.1 List tables and views in the database.
-- TABLE_ROWS may be an estimate for InnoDB tables.
select 
	TABLE_NAME, 
    TABLE_TYPE, 
    TABLE_ROWS
from information_schema.TABLES 
where TABLE_SCHEMA = 'inventory_ops'
order by TABLE_NAME; 


-- 1.2 Count exact rows in the five tables for the first analysis.
select 
	'raw_stock_items' as table_name, 
    count(*) row_count
from raw_stock_items

union all 
select 
	'raw_stock_item_holdings' as table_name, 
    count(*) row_count
from raw_stock_item_holdings

union all 
select 
	'raw_suppliers' as table_name, 
    count(*) row_count
from raw_suppliers

union all 
select 
	'raw_purchase_orders' as table_name, 
    count(*) row_count
from raw_purchase_orders

union all 
select 
	'raw_purchase_order_lines' as table_name, 
    count(*) row_count
from raw_purchase_order_lines; 


-- ============================================================
-- SECTION 2: TABLE STRUCTURE
-- ============================================================

-- 2.1 List all columns in the five tables.
select 
	TABLE_NAME, 
    ORDINAL_POSITION, 
    COLUMN_NAME, 
    DATA_TYPE, 
    IS_NULLABLE, 
    COLUMN_KEY
from information_schema.COLUMNS 
where TABLE_SCHEMA = 'inventory_ops'
	and TABLE_NAME in (
    'raw_stock_items', 
    'raw_stock_item_holdings', 
    'raw_suppliers', 
    'raw_purchase_orders', 
    'raw_purchase_order_lines'
    )
order by TABLE_NAME, ORDINAL_POSITION; 

-- 2.2 Preview the fields needed for the inventory analysis.
SELECT 
	StockItemID, 
    StockItemName, 
    SupplierID, 
    LeadTimeDays,
    QuantityPerOuter
FROM raw_stock_items
LIMIT 10; 


-- ============================================================
-- SECTION 3: TABLE-LEVEL DATA QUALITY CHECKS
-- ============================================================

-- 3.1 Check StockItemID for missing and duplicate values.
select 
	count(*) as total_rows, 
    sum(
    StockItemID is null or trim(StockItemID) = ''
    ) missing_stock_item_id, 
    count(
    distinct nullif(trim(StockItemID), '')
    ) distinct_stock_item_ids, 
    count(nullif(trim(StockItemID), '')) - count(distinct nullif(trim(StockItemID), '')) duplicate_extra_rows
from raw_stock_items; 


-- 3.2 Check required fields and integer formats in stock items.
select 
	count(*) as total_rows, 
    sum(
		StockItemName is null 
        or trim(StockItemName) = ''
    ) as missing_stocks_item_name, 
    sum(
		StockItemID is null 
        or trim(StockItemID) not regexp '^[0-9]+$'
    ) invalid_stocks_item_id, 
    sum(
		SupplierID is null
        or trim(SupplierID) not regexp '^[0-9]+$'
    ) invalid_supplier_id, 
    sum(
		LeadTimeDays is null
        or trim(LeadTimeDays) not regexp '^[0-9]+$'
    ) invalid_lead_time_days, 
    sum(
		QuantityPerOuter is null
        or trim(QuantityPerOuter) not regexp '^[0-9]+$'
        or trim(QuantityPerOuter) regexp '^0+$'
    ) as invalid_quantity_per_outer
from raw_stock_items; 

-- 3.3 Find stock items without a matching supplier.
select 
	si.StockItemID, 
    si.StockItemName, 
    si.SupplierID, 
    s.SupplierID
from raw_stock_items si
left join raw_suppliers s 
on trim(si.SupplierID) = trim(s.SupplierID)
where s.SupplierID is null; 

-- 3.4 Inspect numeric ranges in stock items.
select 
	min(cast(trim(StockItemID) as unsigned)) as min_stock_item_id, 
    max(cast(trim(StockItemID) as unsigned)) as max_stock_item_id, 
	min(cast(trim(SupplierID) as unsigned)) as min_SupplierID, 
    max(cast(trim(SupplierID) as unsigned)) as max_SupplierID, 
	min(cast(trim(LeadTimeDays) as unsigned)) as min_LeadTimeDays, 
    max(cast(trim(LeadTimeDays) as unsigned)) as max_LeadTimeDays, 
	min(cast(trim(QuantityPerOuter) as unsigned)) as min_QuantityPerOuter, 
    max(cast(trim(QuantityPerOuter) as unsigned)) as max_QuantityPerOuter
from raw_stock_items; 

-- 3.5 Check the candidate primary key in stock item holdings.
select 
	count(*) as total_rows, 
    sum(
		StockItemID is null
        or trim(StockItemID) = ''
    ) as misiing_stock_item_id, 
    count(
		distinct nullif(trim(StockItemID), '')
    ) as distinct_stock_item_id, 
    count(nullif(trim(StockItemID), '')) - count(distinct nullif(trim(StockItemID), ''))  duplicate_extra_rows
from raw_stock_item_holdings; 



-- 3.6 Check the relationship between stock items and holdings.

-- Holdings without a matching stock item.
select 
	'holdings_without_stock_item' as check_name, 
    count(*) as unmatched_rows
from raw_stock_item_holdings h 
left join raw_stock_items as si 
	on trim(h.StockItemID) = trim(si.StockItemID)
where si.StockItemID is null

union all 

select
	 'stock_items_without_holdings' as check_name, 
     count(*) as unmatched_rows
from raw_stock_items si 
left join raw_stock_item_holdings as h 
	on trim(si.StockItemID) = trim(h.StockItemID)
where h.StockItemID is null;



-- 3.7 Check missing values and integer formats in holdings.
select 
	count(*) as total_rows, 
    sum(
		QuantityOnHand is null 
        or trim(QuantityOnHand) = ''
    ) as missing_QuantityOnHand, 
	sum(
		QuantityOnHand IS NOT NULL
		AND trim(QuantityOnHand) <> ''
		AND trim(QuantityOnHand) not regexp '^-?[0-9]+$'
	) AS invalid_QuantityOnHand,
    sum(
		ReorderLevel is null
        or trim(ReorderLevel) = ''
    ) as missing_ReorderLevel, 
    sum(
		ReorderLevel is not null 
        and trim(ReorderLevel) != ''
        and trim(ReorderLevel) not regexp '^-?[0-9]+$'
    ) invalid_ReorderLevel, 
    sum(
		TargetStockLevel is null
        or trim(TargetStockLevel) = ''
    ) missing_TargetStockLevel, 
    sum(
		TargetStockLevel is not null
        and trim(TargetStockLevel) != ''
        and trim(TargetStockLevel) not regexp '^-?[0-9]+$'
    )invalid_target_stock_level
from raw_stock_item_holdings; 



-- 3.8 Check numeric ranges and business rules in holdings.
with typed as(
	select 
		cast(trim(QuantityOnHand) as signed ) as QuantityOnHand, 
        cast(trim(ReorderLevel) as signed ) as ReorderLevel, 
        cast(trim(TargetStockLevel) as signed ) as TargetStockLevel
    from raw_stock_item_holdings
)

select 
	min(QuantityOnHand) as min_QuantityOnHand, 
    max(QuantityOnHand) as max_QuantityOnHand, 
    min(ReorderLevel) as min_ReorderLevel, 
    max(ReorderLevel) as max_ReorderLevel, 
    min(TargetStockLevel) as min_TargetStockLevel, 
    max(TargetStockLevel) as max_TargetStockLevel, 
    
    sum(QuantityOnHand < 0) as negative_QuantityOnHand, 
    sum(ReorderLevel < 0 ) as negative_ReorderLevel, 
    sum(TargetStockLevel < 0) as negative_TargetStockLevel, 
    sum(TargetStockLevel < ReorderLevel ) as target_below_reorder_rows
from typed; 

-- 3.9 Check supplier identifiers and names.
select 
	count(*) as total_rows, 
    sum(
		SupplierID is null
        or trim(SupplierID) = ''
    ) as missing_SupplierID, 
    count(distinct nullif(trim(SupplierID), '')) as distinct_SupplierID, 
    count(nullif(trim(SupplierID),'')) - count(distinct nullif(trim(SupplierID),'')) as duplicate_extra_rows, 
    sum(
		SupplierID is not null 
        and trim(SupplierID) != ''
        and trim(SupplierID) not regexp '^[0-9]+$'
    ) invalid_SupplierID, 
    sum(
		SupplierName is null
        or trim(SupplierName) = ''
    ) as missing_SupplierName
from raw_suppliers; 

-- 3.10 Check purchase order identifiers.alter.

select 
	count(*) as total_rows, 
    sum(
		PurchaseOrderID is null
        or trim(PurchaseOrderID) = ''
    ) missing_PurchaseOrderID, 
    count(
		distinct nullif(trim(PurchaseOrderID),'')
    ) distinct_PurchaseOrderID, 
    count(nullif(trim(PurchaseOrderID),'')) 
    - count(distinct nullif(trim(PurchaseOrderID),'')) as duplicate_PurchaseOrderID, 
    sum(
		PurchaseOrderID is not null
        and trim(PurchaseOrderID) != ''
        and trim(PurchaseOrderID) not regexp '^[0-9]+$'
    ) invalid_PurchaseOrderID, 
    sum(
		SupplierID is null 
        or trim(SupplierID) = ''
    ) missing_SupplierID, 
    sum(
		SupplierID is not null
        and trim(SupplierID) != ''
        and trim(SupplierID) not regexp '^[0-9]+$'
    ) as invalid_SupplierID
from raw_purchase_orders; 


-- 3.11 Count purchase orders without a matching supplier.
select 
	count(*) as purchase_orders_without_supplier
from raw_purchase_orders po
left join raw_suppliers s
on trim(po.SupplierID) = trim(s.SupplierID)
where s.SupplierID is null; 


-- 3.12 Check missing purchase order dates.
select 
	count(*) as total_rows, 
    sum(
		OrderDate is null 
        or trim(OrderDate) = ''
    ) missing_OrderDate, 
    sum(
		ExpectedDeliveryDate is null 
        or trim(ExpectedDeliveryDate) = ''
    ) missinfg_ExpectedDeliveryDate
from raw_purchase_orders; 


-- 3.13 Preview raw date values.
select 
	PurchaseOrderID, 
    OrderDate, 
    ExpectedDeliveryDate
from raw_purchase_orders
limit 10; 

-- Inspect all distinct finalized status values.
select 
	IsOrderFinalized, 
    hex(IsOrderFinalized), 
    count(*) as raw_count
from raw_purchase_orders
group by IsOrderFinalized, hex(IsOrderFinalized); 


-- 3.14 Validate the format and calendar dates of all purchase orders.
WITH date_values AS (
    SELECT
        PurchaseOrderID,
        'OrderDate' AS field_name,
        TRIM(OrderDate) AS raw_value
    FROM raw_purchase_orders

    UNION ALL

    SELECT
        PurchaseOrderID,
        'ExpectedDeliveryDate',
        TRIM(ExpectedDeliveryDate)
    FROM raw_purchase_orders
),
validated AS (
    SELECT
        *,
        CASE
            WHEN raw_value IS NULL OR raw_value = ''
                THEN 'missing'

            WHEN raw_value NOT REGEXP
                '^[1-9][0-9]{3}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$'
                THEN 'invalid_format'

            WHEN CAST(RIGHT(raw_value, 2) AS UNSIGNED)
                 > DAY(
                     LAST_DAY(
                         CONCAT(LEFT(raw_value, 7), '-01')
                     )
                 )
                THEN 'invalid_calendar_date'

            ELSE 'valid'
        END AS validation_status
    FROM date_values
)


SELECT
    field_name,
    validation_status,
    COUNT(*) AS row_count
FROM validated
GROUP BY field_name, validation_status
ORDER BY field_name, validation_status;




-- 3.15 Check purchase order date ranges and business rules.
with typed as(
	select 
		cast(trim(OrderDate)as date) as OrderDate, 
        cast(trim(ExpectedDeliveryDate) as date) as ExpectedDeliveryDate
	from raw_purchase_orders
)

select 
	min(OrderDate) as earlist_OrderDate, 
    max(OrderDate) as latest_OrderDate, 
    min(ExpectedDeliveryDate) as earlist_ExpectedDeliveryDate, 
    max(ExpectedDeliveryDate) as latest_ExpectedDeliveryDate, 
    sum(
    ExpectedDeliveryDate < OrderDate
    ) as delivery_before_order_rows, 
    sum(
		OrderDate > '2016-05-31'
    ) orders_after_reference_date, 
    min(
		datediff(ExpectedDeliveryDate, OrderDate)
    ) min_planned_delivery_day, 
    max(
		datediff(ExpectedDeliveryDate, OrderDate)
    ) max_planned_delivery_day
from typed; 



-- 3.16 Check the candidate primary key in purchase order lines.
select 
	count(*) total_rows, 
    sum(
		PurchaseOrderLineID is null
        or trim(PurchaseOrderLineID) = ''
    ) as missing_PurchaseOrderLineID, 
    
    count(
    distinct nullif(trim(PurchaseOrderLineID),'')
    ) as distinct_PurchaseOrderLineID, 
    
    count(nullif(trim(PurchaseOrderLineID),''))
    -count(distinct nullif(trim(PurchaseOrderLineID),'')) as duplicate_extra_rows, 
    
    sum(
    PurchaseOrderLineID is not null
    and trim(PurchaseOrderLineID) != ''
    and trim(PurchaseOrderLineID) not regexp '^[0-9]+$'
    ) as invalid_line_id
    
from raw_purchase_order_lines; 

-- 3.17 Check purchase order line relationships.

select 
	'line without purchase order' as check_name, 
    count(*) as unmatched_rows
from raw_purchase_order_lines as pol 
left join raw_purchase_orders po
on trim(pol.PurchaseOrderID) = trim(po.PurchaseOrderID)
where po.PurchaseOrderID is null

union all 

select 
	'line without stock item' as check_name, 
    count(*) as unmatched_rows
from raw_purchase_order_lines pol
left join raw_stock_items si
on trim(pol.StockItemID) = trim(si.StockItemID)
where si.StockItemID is null

union all 

select 
	'purchase orders without lines' as check_name, 
    count(*) as unmatched_rows
from raw_purchase_orders po
left join raw_purchase_order_lines pol
on trim(po.PurchaseOrderID) = trim(pol.PurchaseOrderID)
where pol.PurchaseOrderID is null; 


-- 3.18 Check missing values and integer formats of quantities.
select 
	count(*) as total_rows, 
    sum(
		OrderedOuters is null
        or trim(OrderedOuters) = ''
    ) as missing_OrderedOuters, 
    sum(
		OrderedOuters is not null 
        and trim(OrderedOuters) != ''
        and trim(OrderedOuters) not regexp '^-?[0-9]+$'
    ) as invalid_OrderedOuters, 
    sum(
		ReceivedOuters is null
        or trim(ReceivedOuters) = ''
    ) missing_ReceivedOuters, 
    sum(
		ReceivedOuters is not null 
        and trim(ReceivedOuters) != ''
        and trim(ReceivedOuters) not regexp '^-?[0-9]+$'
    ) as invalid_ReceivedOuters
from raw_purchase_order_lines; 

-- 3.19 Check quantity ranges and business rules.
with typed as (
	select 
		cast(trim(OrderedOuters) as signed) as OrderedOuters, 
        cast(trim(ReceivedOuters) as signed ) as ReceivedOuters
    from raw_purchase_order_lines
)

select 
	min(OrderedOuters) as min_OrderedOuters, 
    max(OrderedOuters) as max_OrderedOuters, 
    min(ReceivedOuters) as min_ReceivedOuters, 
    max(ReceivedOuters) as max_ReceivedOuters, 
    
    sum(ReceivedOuters < 0) negative_ReceivedOuters, 
    sum(OrderedOuters < 0) negative_OrderedOuters, 
    sum(OrderedOuters = 0) as zero_OrderedOuters, 
    sum(OrderedOuters < ReceivedOuters) as over_received_rows, 
    sum(OrderedOuters > ReceivedOuters) as not_fully_received_rows
from typed; 

-- 3.20 Compare receipt quantities with finalized status.
WITH typed AS (
    SELECT
        CAST(TRIM(OrderedOuters) AS SIGNED) AS ordered_outers,
        CAST(TRIM(ReceivedOuters) AS SIGNED) AS received_outers,
        CASE
            WHEN LOWER(TRIM(IsOrderLineFinalized)) IN ('true', '1')
                THEN 'finalized'
            WHEN LOWER(TRIM(IsOrderLineFinalized)) IN ('false', '0')
                THEN 'open'
            ELSE 'unknown'
        END AS line_status
    FROM raw_purchase_order_lines
),
classified AS (
    SELECT
        *,
        CASE
            WHEN received_outers = ordered_outers
                THEN 'fully_received'
            WHEN received_outers = 0
                THEN 'not_received'
            WHEN received_outers < ordered_outers
                THEN 'partially_received'
            ELSE 'over_received'
        END AS receipt_status
    FROM typed
)
SELECT
    receipt_status,
    line_status,
    COUNT(*) AS row_count
FROM classified
GROUP BY receipt_status, line_status
ORDER BY receipt_status, line_status;


-- 3.21 Compare receipt date availability with received quantity.
WITH checked AS (
    SELECT
        CAST(TRIM(ReceivedOuters) AS SIGNED) AS received_outers,
        NULLIF(TRIM(LastReceiptDate), '') AS receipt_date
    FROM raw_purchase_order_lines
)
SELECT
    COUNT(*) AS total_rows,

    SUM(receipt_date IS NULL) AS missing_receipt_date,

    SUM(
        received_outers > 0
        AND receipt_date IS NULL
    ) AS received_without_date,

    SUM(
        received_outers = 0
        AND receipt_date IS NOT NULL
    ) AS no_receipt_with_date

FROM checked;


-- 3.22 Preview nonempty receipt date values.
SELECT
    PurchaseOrderLineID,
    ReceivedOuters,
    LastReceiptDate
FROM raw_purchase_order_lines
WHERE NULLIF(TRIM(LastReceiptDate), '') IS NOT NULL
LIMIT 10;


-- 3.23 Validate the format and calendar validity of receipt dates.
WITH date_values AS (
    SELECT
        NULLIF(TRIM(LastReceiptDate), '') AS raw_value
    FROM raw_purchase_order_lines
),
validated AS (
    SELECT
        CASE
            WHEN raw_value IS NULL
                THEN 'missing'

            WHEN raw_value NOT REGEXP
                '^[1-9][0-9]{3}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$'
                THEN 'invalid_format'

            WHEN CAST(RIGHT(raw_value, 2) AS UNSIGNED)
                 > DAY(
                     LAST_DAY(
                         CONCAT(LEFT(raw_value, 7), '-01')
                     )
                 )
                THEN 'invalid_calendar_date'

            ELSE 'valid'
        END AS validation_status
    FROM date_values
)
SELECT
    validation_status,
    COUNT(*) AS row_count
FROM validated
GROUP BY validation_status
ORDER BY validation_status;


-- 3.24 Check receipt date ranges and chronological consistency.
-- Run after 3.14 and 3.23 confirm that nonempty dates are valid.
WITH typed AS (
    SELECT
        CAST(TRIM(pol.LastReceiptDate) AS DATE) AS receipt_date,
        CAST(TRIM(po.OrderDate) AS DATE) AS order_date,
        CAST(TRIM(po.ExpectedDeliveryDate) AS DATE)
            AS expected_delivery_date
    FROM raw_purchase_order_lines AS pol
    JOIN raw_purchase_orders AS po
        ON TRIM(pol.PurchaseOrderID) = TRIM(po.PurchaseOrderID)
    WHERE NULLIF(TRIM(pol.LastReceiptDate), '') IS NOT NULL
)
SELECT
    COUNT(*) AS received_lines,
    MIN(receipt_date) AS earliest_receipt_date,
    MAX(receipt_date) AS latest_receipt_date,

    SUM(receipt_date < order_date)
        AS receipt_before_order_rows,

    SUM(receipt_date > '2016-05-31')
        AS receipt_after_reference_date_rows,

    SUM(receipt_date < expected_delivery_date)
        AS last_receipt_before_expected_rows,

    SUM(receipt_date = expected_delivery_date)
        AS last_receipt_on_expected_rows,

    SUM(receipt_date > expected_delivery_date)
        AS last_receipt_after_expected_rows

FROM typed;


-- 3.25 Check purchase package compatibility with stock items.
-- Matching IDs do not establish historical conversion factors.
SELECT
    COUNT(*) AS total_lines,

    SUM(
        pol.PackageTypeID IS NULL
        OR TRIM(pol.PackageTypeID) = ''
    ) AS missing_purchase_package,

    SUM(
        si.OuterPackageID IS NULL
        OR TRIM(si.OuterPackageID) = ''
    ) AS missing_item_outer_package,

    SUM(
        NULLIF(TRIM(pol.PackageTypeID), '') IS NOT NULL
        AND NULLIF(TRIM(si.OuterPackageID), '') IS NOT NULL
        AND TRIM(pol.PackageTypeID) <> TRIM(si.OuterPackageID)
    ) AS package_mismatch_rows

FROM raw_purchase_order_lines AS pol
JOIN raw_stock_items AS si
    ON TRIM(pol.StockItemID) = TRIM(si.StockItemID);


-- 3.26 Compare purchase order and line finalized statuses.
SELECT
    LOWER(TRIM(po.IsOrderFinalized)) AS order_finalized,
    LOWER(TRIM(pol.IsOrderLineFinalized)) AS line_finalized,
    COUNT(*) AS line_count
FROM raw_purchase_order_lines AS pol
JOIN raw_purchase_orders AS po
    ON TRIM(pol.PurchaseOrderID) = TRIM(po.PurchaseOrderID)
GROUP BY
    LOWER(TRIM(po.IsOrderFinalized)),
    LOWER(TRIM(pol.IsOrderLineFinalized))
ORDER BY order_finalized, line_finalized;
