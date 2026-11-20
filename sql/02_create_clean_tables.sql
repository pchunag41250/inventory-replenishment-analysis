-- ============================================================
-- Inventory Operations Project
-- Create and Populate Clean Tables
--
-- Goal:
--   Transform the audited raw data into typed, relational tables
--   for inventory and purchasing risk analysis.
--
-- Analysis reference date: 2016-05-31
--
-- Prerequisites:
--   1. Run 01_structured_data_audit.sql against the current raw data.
--   2. Resolve blocking data quality issues before loading.
--   3. Validate integer ranges and uniqueness after conversion.
--   4. Confirm text lengths for columns with length limits.
--
-- Source tables:
--   1. raw_suppliers
--   2. raw_stock_items
--   3. raw_stock_item_holdings
--   4. raw_purchase_orders
--   5. raw_purchase_order_lines
--
-- Target tables and dependency order:
--   1. clean_suppliers
--   2. clean_stock_items
--   3. clean_stock_item_holdings
--   4. clean_purchase_orders
--   5. clean_purchase_order_lines
--
-- Transformation rules:
--   1. Preserve the source raw tables.
--   2. Include fields required for the first analysis.
--   3. Trim leading and trailing spaces in selected text fields.
--   4. Convert validated identifiers and quantities to integers.
--   5. Convert validated date strings to DATE values.
--   6. Map recognized finalized statuses to 1 or 0.
--   7. Preserve NULL receipt dates for lines not yet received.
--   8. Reject unexpected values rather than silently replacing them.
--   9. Define primary keys, foreign keys, and validated constraints.
--
-- Workflow:
--   1. Confirm the target schema and loading prerequisites.
--   2. Create clean tables in dependency order.
--   3. Transform and load the audited raw data.
--   4. Validate row counts and transformed values.
--   5. Verify key relationships and business rules.
--
-- Expected row counts for the current source snapshot:
--   clean_suppliers:                 13
--   clean_stock_items:              227
--   clean_stock_item_holdings:      227
--   clean_purchase_orders:        2074
--   clean_purchase_order_lines:   8367
--
-- Limitations:
--   These tables represent the imported source snapshot.
--   They do not reconstruct daily historical inventory or
--   historical purchase order statuses.
--   Package conversion uses the current product master data.
--
-- Execution notes:
--   This file is intended for initial clean-layer setup.
--   A repeatable refresh strategy will be implemented separately.
--   Do not bypass duplicate-key or foreign-key errors.
--   MySQL DDL statements can cause implicit commits.
-- ============================================================

USE inventory_ops;

-- ============================================================
-- SECTION 1: SUPPLIERS
-- ============================================================

-- 1.1 Validate supplier IDs and names before conversion.

with normalized as (
	select 
    SupplierID, 
    SupplierName,
    trim(leading '0' from trim(SupplierID)) as normalized_id
    from raw_suppliers
), 
validated as (
	select 
		*, 
        case 
			when SupplierID is null 
            or trim(SupplierID) not regexp '^[0-9]+$' 
				then 0 
            when normalized_id = ''
				then 0 
			when char_length(normalized_id) < 10
				then 1 
			when char_length(normalized_id) = 10 
				and strcmp(normalized_id, '2147483647') <= 0
				then 1
			else 0
		end as valid_id 
    from normalized
)

select 
	count(*) as total_rows, 
    sum(valid_id = 0) as invalid_or_out_of_range_ids,
    count(case when valid_id = 1 then normalized_id end)
    - count(distinct case when valid_id =1 then normalized_id end) AS duplicate_ids_after_conversion,
    sum(
		SupplierName is null
        or trim(SupplierName) = ''
    ) as missing_SupplierName, 
    sum(
		char_length(trim(SupplierName)) > 255
    ) AS names_over_255_chars,
    max(char_length(trim(SupplierName))) as max_name_length
from validated; 


-- 1.2 Create the clean supplier table.

create table clean_suppliers(
	SupplierID INT not null, 
    SupplierName varchar(255) not null, 
    
    primary key(Supplierid), 
    
    constraint chk_clean_suppliers_positive_id
		check(SupplierID > 0), 
	constraint chk_clean_suppliers_nonempty_name
		check(char_length(trim(SupplierName)) > 0)
)engine = InnoDB
default character set = utf8mb4; 


-- 1.3 Transform and load suppliers.
insert into clean_suppliers(
	SupplierID, 
    SupplierName
)

select 
	cast(trim(SupplierID) as signed ), 
    trim(SupplierName)
from raw_suppliers; 


-- 1.4 Compare source and target row counts.
select 
	'raw_suppliers' as table_name, 
    count(*) as row_count
from raw_suppliers

union all 

select
	'clean_suppliers', 
    count(*)
from clean_suppliers; 

-- 1.5 Verify that transformed values match the source.
-- Expected result: 0.
select 
	count(*) as mismatched_rows
from raw_suppliers as r 
left join clean_suppliers as c
	on cast(trim(r.SupplierID) as signed ) = c.SupplierID
where c.SupplierID is null
	OR NOT (
    CAST(c.SupplierName AS BINARY)
    <=> CAST(TRIM(r.SupplierName) AS BINARY)
); 


-- 1.6 Inspect the clean data and table definition.
select * 
from clean_suppliers
order by SupplierID; 

show create table clean_suppliers; 


-- ============================================================
-- SECTION 2: STOCK ITEMS
-- ============================================================

-- 2.1 Validate integer fields before conversion.

with field_values as (
	select 
		'StockItemID' as field_name, 
        trim(StockItemID) as raw_value, 
        1 as minimum_value
    from raw_stock_items
    
    union all 
    
    select 
		'SupplierID', 
        trim(SupplierID), 
        1 
    from raw_stock_items
    
    union all 
    
    select 
		'LeadTimeDays', 
        trim(LeadTimeDays), 
        0
    from raw_stock_items
    
    union all 
    
    select 
		'QuantityPerOuter', 
        trim(QuantityPerOuter), 
        1
	from raw_stock_items
    
    union all 
    
    select 
		'OuterPackageID', 
        trim(OuterPackageID), 
        1
    from raw_stock_items
), 
normalized as(
	select
		*, 
        coalesce(
			nullif(trim(leading '0' from raw_value),''), '0'
        ) as normalized_value
	from field_values
), 
validated as(
    SELECT
        *,
        CASE
            WHEN raw_value IS NULL
                OR raw_value NOT REGEXP '^[0-9]+$'
                THEN 0

            WHEN CHAR_LENGTH(normalized_value) > 10
                THEN 0

            WHEN CHAR_LENGTH(normalized_value) = 10
                AND STRCMP(normalized_value, '2147483647') > 0
                THEN 0

            WHEN minimum_value = 1
                AND normalized_value = '0'
                THEN 0

            ELSE 1
        END AS is_valid
    FROM normalized
)

select 
	field_name, 
    count(*) as total_rows, 
    sum(is_valid = 0) as invalid_rows
from validated 
group by field_name
order by field_name; 


-- 2.2 Validate stock item names.
select 
	count(*) as total_rows, 
    sum(
		StockItemName is null
        or trim(StockItemName) = ''
    ) as missing_names, 
    sum(
		char_length(trim(StockItemName)) > 255
    ) names_over_255_chars, 
    max(
		char_length(trim(StockItemName))
    ) max_name_length
from raw_stock_items; 


-- 2.3 Check stock item ID uniqueness after integer conversion.
select 
	count(*) 
    as total_rows, 
    count(distinct cast(trim(StockItemID) as signed)) 
    as distinct_converted_ids, 
    count(*) - count(distinct cast(trim(StockItemID) as signed)) 
    as duplicate_ids_after_conversion 
from raw_stock_items; 


-- 2.4 Check supplier references against the clean supplier table.
select 
	count(*) as items_without_clean_supplier
from raw_stock_items as si 
left join clean_suppliers s 
	on cast(trim(si.SupplierID) as signed) = s.SupplierID
where s.SupplierID is null; 


-- 2.5 Create the clean stock items table.
 create table clean_stock_items(
	stockitemID INT NOT NUll, 
    StockItemName varchar(255) NOT NULL, 
    SupplierID INT NOT NULL, 
    LeadTimeDays INT NOT NULL, 
    QuantityPerOuter INT NOT NULL, 
    OuterPackageID INT NOT NULL,
    
    PRIMARY KEY(StockItemID), 
    
    constraint fk_clean_stock_items_supplier
		foreign key(SupplierID)
        references clean_suppliers (SupplierID), 
        
	constraint chk_clean_stock_items_positive_id
		check(StockItemID > 0), 
        
	constraint chk_clean_stock_items_nonempty_name
		check(char_length(trim(StockItemName))> 0), 
        
    constraint chk_clean_stock_items_lead_time
        check (LeadTimeDays >= 0),
        
    constraint chk_clean_stock_items_quantity_per_outer
        check (QuantityPerOuter > 0),
        
    constraint chk_clean_stock_items_outer_package
        check (OuterPackageID > 0)
 ) engine = InnoDB
 
 default charset = utf8mb4; 
 
 
-- 2.6 Transform and load stock items.
insert into clean_stock_items(
	stockitemID,
    StockItemName, 
    SupplierID,
    LeadTimeDays, 
    QuantityPerOuter, 
    OuterPackageID
)

select 
	cast(trim(StockItemID) as signed), 
    trim(StockItemName), 
    cast(trim(SupplierID) as signed), 
    cast(trim(LeadTimeDays) as signed), 
    cast(trim(QuantityPerOuter) as signed), 
    cast(trim(OuterPackageID) as signed)
from raw_stock_items; 


-- 2.7 Compare raw and clean row counts.
select 
	'raw_stock_items' as table_name, 
    count(*) as total_rows
from raw_stock_items

union all 

select 
	'clean_stock_items', 
    count(*)
from clean_stock_items; 

-- Check that every raw row matches its transformed clean row.
SELECT COUNT(*) AS mismatched_rows
FROM raw_stock_items AS r
LEFT JOIN clean_stock_items AS c
    ON CAST(TRIM(r.StockItemID) AS SIGNED) = c.StockItemID
WHERE c.StockItemID IS NULL
   OR NOT (
       CAST(c.StockItemName AS BINARY)
       <=> CAST(TRIM(r.StockItemName) AS BINARY)
   )
   OR NOT (
       c.SupplierID
       <=> CAST(TRIM(r.SupplierID) AS SIGNED)
   )
   OR NOT (
       c.LeadTimeDays
       <=> CAST(TRIM(r.LeadTimeDays) AS SIGNED)
   )
   OR NOT (
       c.QuantityPerOuter
       <=> CAST(TRIM(r.QuantityPerOuter) AS SIGNED)
   )
   OR NOT (
       c.OuterPackageID
       <=> CAST(TRIM(r.OuterPackageID) AS SIGNED)
   );
    
    
-- 2.8 Inspect loaded data and table definition.
select *
from clean_stock_items
order by stockitemID
limit 10; 

show create table clean_stock_items; 

-- SECTION 3: STOCK ITEM HOLDINGS

-- 3.1 Validate integer formats and ranges before conversion.
with field_values as(
	select
		'stockitemID' as field_name, 
        trim(stockitemID) as raw_value
    from raw_stock_item_holdings
    
    union all 
    
    select 
		'QuantityOnHand', 
        trim(QuantityOnHand)
    from raw_stock_item_holdings
    
    union all 
    
    select 
    'ReorderLevel', 
    trim(ReorderLevel)
    from raw_stock_item_holdings
    
    union all 
    
    select 
    'TargetStockLevel', 
    trim(TargetStockLevel)
    from raw_stock_item_holdings

), 
normalized as (
	select 
		*, 
        left(raw_value, 1) = '-' is_negative,
        COALESCE(
            NULLIF(
                TRIM(LEADING '0' FROM
                    CASE
                        WHEN LEFT(raw_value, 1) = '-'
                            THEN SUBSTRING(raw_value, 2)
                        ELSE raw_value
                    END
                ),
                ''
            ),
            '0'
        ) AS magnitude
    from field_values
), 
validated as (
	select 
    *, 
		case 
			when raw_value is null 
            or raw_value not regexp '^-?[0-9]+$'
            then 0 
            when char_length(magnitude) > 10
            then 0
            when char_length(magnitude) = 10 
				and strcmp(
                magnitude, 
                case 
					when is_negative = 1 then '2147483648'
                    else '2147483647'
				end
                ) > 0
                then 0 
			when field_name = 'StockItemID'
				and (is_negative = 1 or magnitude = '0')
                then 0 
			when field_name in ('ReorderLevel', 'TargetstockLevel')
				and is_negative =1 
                and magnitude != '0'
                then 0 
			else 1
            end as is_valid
    from normalized
)

select 
	field_name, 
    count(*) total_rows, 
    sum(is_valid = 0 ) as invalid_name
from validated
group by field_name
order by field_name; 



-- 3.2 Check stock item ID uniqueness after conversion.
select 
	count(*) as total_rows, 
    count(distinct cast(trim(StockItemID) as signed)) as distinct_converted_ids, 
    count(*) - count(distinct cast(trim(StockItemID) as signed)) as duplicate_ids_after_conversion
from raw_stock_item_holdings; 


-- 3.3 Check references to clean stock items.
select 
	count(*) as hoilding_without_clean_item
from raw_stock_item_holdings h 
left join clean_stock_items as s
	on cast(trim(h.stockitemID) as signed) = s.stockitemID
where s.stockitemID is null; 

-- Check that target stock is not below the reorder level.

select 
	count(*) target_below_reorder_rows
from raw_stock_item_holdings
where cast(trim(TargetStockLevel) as signed) < cast(trim(ReorderLevel) as signed); 


-- 3.4 Create the clean stock item holdings table.

create table clean_stock_item_holdings(
	StockItemID int not null, 
    QuantityOnHand int not null, 
    ReorderLevel int not null, 
    TargetStockLevel int not null, 
    
    primary key(StockItemID), 
    
    constraint fk_clean_holdings_stock_item
		foreign key(stockitemID)
        references clean_stock_items(stockitemid), 
	
    constraint chk_clean_hoildings_positive_id
		check(StockItemID > 0), 
	
    constraint chk_clean_holdings_reorder_level
		check(ReorderLevel >= 0), 

    constraint chk_clean_holdings_target_level
		check(TargetStockLevel >= 0), 
        
    constraint chk_clean_holdings_target_vs_reorder
		check(TargetStockLevel >= ReorderLevel) 
) engine = InnoDB

Default CHARSET = utf8mb4; 

-- 3.5 Transform and load stock item holdings.
insert into clean_stock_item_holdings (
	StockItemID, 
    QuantityOnHand, 
    ReorderLevel, 
    TargetStockLevel
)

select 
	cast(trim(StockItemID) as signed), 
    cast(trim(QuantityOnHand) as signed), 
    cast(trim(ReorderLevel) as signed), 
    cast(trim(TargetStockLevel) as signed)
from raw_stock_item_holdings; 

-- 3.6 Compare raw and clean row counts.

select 
	'raw_stock_item_holdings' as table_name, 
    count(*) total_rows
from raw_stock_item_holdings

union all 

select 
	'clean_stock_item_holding', 
    count(*)
from clean_stock_item_holdings; 


-- 3.7 Check that raw values match transformed clean values.
select 
	count(*) as mismatched_rows
from raw_stock_item_holdings r
left join clean_stock_item_holdings c 
 on cast(trim(r.StockItemID) as signed) = c.StockItemID
 where c.StockItemID is null 
 or c.QuantityOnHand != cast(trim(r.QuantityOnHand) as signed)
 or c.ReorderLevel != cast(trim(r.ReorderLevel) as signed)
 or c.TargetStockLevel != cast(trim(r.TargetStockLevel) as signed); 

-- 3.8 Inspect loaded data and table definition.
select * 
from clean_stock_item_holdings
order by StockItemID
limit 10; 

show create table clean_stock_item_holdings; 

-- SECTION 4: PURCHASE ORDERS

-- 4.1 Validate IDs before integer conversion.

with field_values as (
	select 
		'PurchaseOrderID' as field_name, 
        trim(PurchaseOrderID) raw_value
    from raw_purchase_orders
    
    union all 
    
    select 
    'SupplierID', 
    trim(SupplierID)
    from raw_purchase_orders
), 
normalized as(
	select 
		*, 
        coalesce(
			nullif(trim(leading '0' from raw_value), ''),
        '0') as normalized_value
    from field_values
), 
validated as(
	select 
    *, 
    case 
		when raw_value is null 
			or raw_value not regexp '^[0-9]+$'
            then 0 
		when normalized_value = '0'
			then 0 
		when char_length(normalized_value) > 10 
			then 0 
		when char_length(normalized_value) = 10 
			and strcmp(normalized_value, '2147483647') > 0 
            then 0 
		else 1 
		end as is_valid
    from normalized
)

select 
	field_name, 
    count(*) total_rows, 
    sum(is_valid = 0 ) as invalid_rows
from validated
group by field_name
order by field_name; 

-- 4.2 Check purchase order ID uniqueness after conversion.

select 
	count(*) as total_rows, 
    count(distinct cast(trim(PurchaseOrderID) as signed)) as distinct_converted_ids, 
    count(*) - count(distinct cast(trim(PurchaseOrderID) as signed)) as duplicate_ids_after_conversion
from raw_purchase_orders; 


-- 4.3 Check references to clean suppliers.
select 
	count(*) as orders_without_clean_supplier
from raw_purchase_orders p
left join clean_suppliers s 
	on cast(trim(p.SupplierID) as signed) = s.SupplierID
where s.SupplierID is null; 


-- 4.4 Inspect finalized status values.
select 
	trim(IsOrderFinalized) raw_status, 
    hex(trim(IsOrderFinalized)) status_hex, 
    count(*) as row_count
from raw_purchase_orders
group by 
	trim(IsOrderFinalized), 
    hex(trim(IsOrderFinalized)); 


-- 4.5 Validate dates before conversion.

with date_values as (
	select 
		'OrderDate' as field_name, 
        trim(OrderDate) as raw_values
    from raw_purchase_orders
    
    union all 
    
    select 
		'ExpectedDeliveryDate', 
        trim(ExpectedDeliveryDate)
    from raw_purchase_orders
), 
validated as (
	select 
    *, 
    case 
		when raw_values is null or raw_values = ''
        then 'missing' 
        
        when raw_values not regexp
			 '^[1-9][0-9]{3}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$'
             then 'invalid'
             
		when cast(right(raw_values, 2) as unsigned)
				> day(
					last_day(
						concat(left(raw_values, 7), '-01')
                    )
                )
                then 'invalid'
			else 'valid'
		end as validation_status
	from date_values
)

select 
	field_name, 
    count(*) as total_rows, 
    sum(validation_status = 'missing') as misssing_rows, 
    sum(validation_status = 'invalid') as invalid_rows, 
    sum(validation_status = 'valid') as valid_rows
from validated 
group by field_name
order by field_name; 


-- 4.6 Check delivery date against order date.
select 
	count(*) as delivery_before_order_rows 
from raw_purchase_orders
where cast(trim(ExpectedDeliveryDate) as date) 
		< cast(trim(OrderDate) as date);   


-- 4.7 Create the clean purchase orders table.
create table clean_purchase_orders(
	PurchaseOrderID int not null, 
    SupplierID int not null, 
    OrderDate date not null, 
    ExpectedDeliveryDate date not null, 
    IsOrderFinalized tinyint not null, 
    
    primary key(PurchaseOrderID), 
    
    constraint fk_clean_purchase_orders_suppliers
		foreign key (SupplierID) 
        references clean_suppliers(SupplierID), 
        
	constraint chk_clean_purchase_orders_positive_id
		check(PurchaseOrderID > 0), 
        
	constraint chk_clean_purchase_orders_delivery_date
		check(ExpectedDeliveryDate >= OrderDate ), 
        
	constraint chk_clean_purchase_orders_finalized
		check(IsOrderFinalized in (0,1))
        
        )engine = InnoDB
        
			default CHARSET = utf8mb4; 
        

-- 4.8 Transform and load purchase orders.

insert into clean_purchase_orders (
	PurchaseOrderID, 
    SupplierID, 
    OrderDate, 
    ExpectedDeliveryDate, 
    IsOrderFinalized
)

select 
	cast(trim(PurchaseOrderID) as signed), 
    cast(trim(SupplierID) as signed), 
    cast(trim(OrderDate) as date), 
    cast(trim(ExpectedDeliveryDate) as date), 
    case cast(trim(IsOrderFinalized) as binary) 
		when cast('True' as binary) then 1
        when cast('False' as binary) then 0 
        else null 
	end
from raw_purchase_orders; 

-- 4.9 Compare row counts.
select 
	'raw_purchase_orders' as total_rows, 
    count(*) as total_rows
from raw_purchase_orders

union all 

select 
	'clean_purchase_orders' as total_rows, 
    count(*)
from clean_purchase_orders; 

-- Check transformed values against the raw source.
select 
	count(*) mismatched_rows
from raw_purchase_orders r
left join clean_purchase_orders c 
	on cast(trim(r.PurchaseOrderID) as signed) = c.PurchaseOrderID
where c.PurchaseOrderID is null 
	or not (
    c.SupplierID <=> cast(trim(r.SupplierID) as signed)
    )
    or not (
    c.OrderDate <=> cast(trim(r.OrderDate) as Date)
    )
    or not (
    c.ExpectedDeliveryDate <=> cast(trim(r.ExpectedDeliveryDate) as Date)
    )
    or not (
	CASE CAST(TRIM(r.IsOrderFinalized) AS BINARY)
    WHEN CAST('True' AS BINARY) THEN 1
    WHEN CAST('False' AS BINARY) THEN 0
    ELSE NULL
END
    ); 
    
    
-- 4.10 Inspect loaded data and table definition.
select 
	IsOrderFinalized, 
    count(*) as row_count
from clean_purchase_orders
group by IsOrderFinalized; 


select *
from clean_purchase_orders
order by PurchaseOrderID
limit 10; 

show create table clean_purchase_orders; 


-- SECTION 5: PURCHASE ORDER LINES

-- 5.1 Validate integer fields before conversion.

with field_values as (
	select 
	'PurchaseOrderLineID' as field_name, 
	trim(PurchaseOrderLineID) as raw_value, 
	1 as minimum_value
    from raw_purchase_order_lines
    
    union all 
    
    select 
    'PurchaseOrderID', 
    trim(PurchaseOrderID), 
    1
    from raw_purchase_order_lines
    
    union all 
    
    select 
    'StockItemID', 
    trim(StockItemID), 
    1
    from raw_purchase_order_lines
    
    union all 
    
    select 
    'OrderedOuters', 
    trim(OrderedOuters), 
    1
    from raw_purchase_order_lines
    
    union all
    
    select 
    'ReceivedOuters', 
    trim(ReceivedOuters), 
    0
    from raw_purchase_order_lines
    
    union all 
    
    select 
    'PackageTypeID', 
    trim(PackageTypeID), 
    1
    from raw_purchase_order_lines
), 
normalized as (
	select 
		*, 
        coalesce(
			nullif(trim(leading '0' from raw_value), ''), 
            '0'
        ) as normalized_value
    from field_values
), 
validated as (
	select 
		*, 
        case 
			when raw_value is null
				or raw_value not regexp '^[0-9]+$'
                then 0 
                
			when char_length(normalized_value) > 10
				then 0 
			when char_length(normalized_value) = 10 
				and strcmp(normalized_value, '2147483647') > 0 
                then 0 
			when minimum_value = 1 
				and normalized_value = '0'
                then 0 
			else 1 
		end as is_valid 
    from normalized
)

select 
	field_name, 
    count(*) as total_rows, 
    SUM(is_valid = 0) AS invalid_rows
from validated
group by field_name
order by field_name; 

-- 5.2 Check line ID uniqueness after conversion.
select 
	count(*) as total_rows, 
    count(distinct cast(trim(PurchaseOrderLineID) as signed)) as distinct_converted_ids, 
    count(*) - count(distinct cast(trim(PurchaseOrderLineID) as signed))  as duplicate_ids_after_conversion 
from raw_purchase_order_lines; 


-- 5.3 Check references to clean tables.

select 
	'line_without_clean_order' as check_name, 
    count(*) as unmatched_rows
from raw_purchase_order_lines as l 
left join clean_purchase_orders as p
	on cast(trim(l.PurchaseOrderID) as signed) = p.PurchaseOrderID
    where p.PurchaseOrderID is null
    
union all 

select 
	'line_without_clean_item', 
    count(*)
from raw_purchase_order_lines as l 
left join clean_stock_items as s 
	on cast(trim(l.StockItemID) as signed) = s.StockItemID
where s.stockitemID is null; 

-- 5.4 Inspect line finalized status values.
select 
	trim(IsOrderLineFinalized) as raw_status, 
    hex(trim(IsOrderLineFinalized)) as status_hex, 
    count(*) as row_count
from raw_purchase_order_lines
group by 
	trim(IsOrderLineFinalized), 
    hex(trim(IsOrderLineFinalized)); 

-- 5.5 Validate nullable receipt dates before conversion.
with date_values as (
	select 
		nullif(trim(LastReceiptDate), '') as raw_value
    from raw_purchase_order_lines
), 
validated as (
	select 
    *, 
    case 
		when raw_value is null
			then 'missing'
		when raw_value not regexp 
			'^[1-9][0-9]{3}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$'
            then 'invalid'
		when cast(right(raw_value, 2) as unsigned)
			> day(
				last_day(
					concat(left(raw_value, 7), '-01')
                )
            )
            then 'invalid'
		else 'valid'
	end as validation_status
    from date_values
)

select
	count(* ) total_rows, 
    sum(validation_status = 'missing') as missing_rows, 
    sum(validation_status = 'invalid') as invalid_rows, 
    sum(validation_status = 'valid') as valid_rows
from validated; 

-- Check consistency between receipt quantity and receipt date.
select 
	sum(
		cast(trim(ReceivedOuters) as signed ) > 0 
        and nullif(trim(LastReceiptDate), '') is null 
    ) received_without_date,
    sum(
		cast(trim(ReceivedOuters) as signed) = 0 
        and nullif(trim(LastReceiptDate), '') is not null
    )no_receipt_with_date
from raw_purchase_order_lines; 



-- 5.6 Create the clean purchase order lines table.
create table clean_purchase_order_lines(
	PurchaseOrderLineID int not null, 
    PurchaseOrderID int not null, 
    StockItemID int not null, 
    OrderedOuters int not null, 
    ReceivedOuters int not null, 
    PackageTypeID int not null, 
    LastReceiptDate date null, 
    IsOrderLineFinalized tinyint not null, 
    
    primary key(PurchaseOrderLineID), 
    
    constraint fk_clean_po_lines_order
		foreign key(PurchaseOrderID)
        references clean_purchase_orders(PurchaseOrderID), 
        
	constraint fk_clean_po_stocks_item
		foreign key(StockItemID)
        references clean_stock_items(StockItemID), 
        
	constraint chk_clean_po_lines_positive_id
		check(PurchaseOrderLineID > 0), 
	
    CONSTRAINT chk_clean_po_lines_ordered
        CHECK (OrderedOuters > 0),
        
    CONSTRAINT chk_clean_po_lines_received
        CHECK (ReceivedOuters >= 0),

    CONSTRAINT chk_clean_po_lines_package
        CHECK (PackageTypeID > 0),

    CONSTRAINT chk_clean_po_lines_finalized
        CHECK (IsOrderLineFinalized IN (0, 1))
) ENGINE = InnoDB

	default CHARSET = utf8mb4; 

-- 5.7 Transform and load purchase order lines.

insert into clean_purchase_order_lines(
    PurchaseOrderLineID,
    PurchaseOrderID,
    StockItemID,
    OrderedOuters,
    ReceivedOuters,
    PackageTypeID,
    LastReceiptDate,
    IsOrderLineFinalized
)

select 
    CAST(TRIM(PurchaseOrderLineID) AS SIGNED),
    CAST(TRIM(PurchaseOrderID) AS SIGNED),
    CAST(TRIM(StockItemID) AS SIGNED),
    CAST(TRIM(OrderedOuters) AS SIGNED),
    CAST(TRIM(ReceivedOuters) AS SIGNED),
    CAST(TRIM(PackageTypeID) AS SIGNED),
    CASE
    WHEN LastReceiptDate IS NULL
        OR TRIM(LastReceiptDate) = ''
        THEN NULL
    ELSE CAST(TRIM(LastReceiptDate) AS DATE)
	END,
    CASE CAST(TRIM(IsOrderLineFinalized) AS BINARY)
        WHEN CAST('True' AS BINARY) THEN 1
        WHEN CAST('False' AS BINARY) THEN 0
        ELSE NULL
    END
from raw_purchase_order_lines; 

-- 5.8 Compare raw and clean row counts.

select 
	'raw_purchase_order_lines' as table_name, 
    count(*) as total_rows
from raw_purchase_order_lines

union all 

select 
	'clean_purchase_order_lines', 
    count(*)
from clean_purchase_order_lines; 

-- Check every selected field after transformation.
select 
	count(*) as mismatched_rows
from raw_purchase_order_lines r 
left join clean_purchase_order_lines c 
on cast(trim(r.PurchaseOrderLineID) as signed ) = c.PurchaseOrderLineID
where c.PurchaseOrderLineID is null
	or not(
    c.PurchaseOrderID 
    <=> cast(trim(r.PurchaseOrderID) as signed)
    )
	or not(
    c.StockItemID 
    <=> cast(trim(r.StockItemID) as signed)
    )
	or not(
    c.OrderedOuters 
    <=> cast(trim(r.OrderedOuters) as signed)
    )
	or not(
    c.ReceivedOuters 
    <=> cast(trim(r.ReceivedOuters) as signed)
    )
	or not(
    c.PackageTypeID 
    <=> cast(trim(r.PackageTypeID) as signed)
    )
	or not(
    c.LastReceiptDate
    <=> 
    case
    when r.LastReceiptDate is null 
		or trim(r.LastReceiptDate) = ''
        then null
	else cast(trim(r.LastReceiptDate) as Date)
    end
    )
    or not(
		c.IsOrderLineFinalized
        <=> case cast(trim(r.IsOrderLineFinalized) as binary)
        when cast('True' as binary) then 1
        when cast('False' as binary) then 0 
        else null 
        end
    ); 

-- 5.9 Inspect loaded data and table definition.

select 
	IsOrderLineFinalized, 
    count(*) as row_count, 
    sum(LastReceiptDate is null) as missing_receipt_dates
from clean_purchase_order_lines
group by IsOrderLineFinalized; 

select * 
from clean_purchase_order_lines
order by PurchaseOrderLineID
limit 10; 

show create table clean_purchase_order_lines; 

