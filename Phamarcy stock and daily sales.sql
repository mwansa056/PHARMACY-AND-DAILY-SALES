
-- 1. Medicines table
CREATE TABLE medicines (
    medicine_id SERIAL PRIMARY KEY,
    medicine_name VARCHAR(100) NOT NULL,
    unit_price NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    stock_qty INTEGER NOT NULL CHECK (stock_qty >= 0)
);

-- 2. Sales table
CREATE TABLE sales (
    sale_id SERIAL PRIMARY KEY,
    medicine_id INTEGER NOT NULL,
    quantity INTEGER NOT NULL CHECK (quantity > 0),
    unit_price NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    sold_on DATE NOT NULL,

    CONSTRAINT fk_sales_medicine
        FOREIGN KEY (medicine_id)
        REFERENCES medicines(medicine_id)
);

-- 3. Stock audit table
CREATE TABLE stock_audit (
    audit_id SERIAL PRIMARY KEY,
    medicine_id INTEGER NOT NULL,
    old_qty INTEGER NOT NULL,
    new_qty INTEGER NOT NULL,
    changed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT fk_audit_medicine
        FOREIGN KEY (medicine_id)
        REFERENCES medicines(medicine_id)
);

-- 4. Daily sales table
CREATE TABLE daily_sales (
    sales_date DATE PRIMARY KEY,
    total_qty INTEGER NOT NULL DEFAULT 0,
    total_amount NUMERIC(12,2) NOT NULL DEFAULT 0
);

INSERT INTO medicines (medicine_name, unit_price, stock_qty)
VALUES
    ('Paracetamol', 5.00, 100),
    ('Amoxicillin', 12.50, 50),
    ('Ibuprofen', 8.00, 75);

CREATE OR REPLACE FUNCTION fn_sale_value(
    p_medicine_id INTEGER,
    p_quantity INTEGER
)
RETURNS NUMERIC(12,2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_price NUMERIC(10,2);
BEGIN
    -- Validate quantity
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Quantity must be positive';
    END IF;

    -- Find the current medicine price
    SELECT unit_price
    INTO v_price
    FROM medicines
    WHERE medicine_id = p_medicine_id;

    -- Reject unknown medicine
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Medicine does not exist';
    END IF;

    -- Return sale value
    RETURN v_price * p_quantity;
END;
$$;

SELECT fn_sale_value(1, 5);


CREATE OR REPLACE PROCEDURE pr_record_sale(
    p_medicine_id INTEGER,
    p_quantity INTEGER,
    p_sold_on DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_price NUMERIC(10,2);
    v_stock INTEGER;
BEGIN
    -- Validate quantity
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Quantity must be positive';
    END IF;

    -- Validate sale date
    IF p_sold_on IS NULL THEN
        RAISE EXCEPTION 'Sale date is required';
    END IF;

    -- Lock and retrieve the medicine
    SELECT unit_price, stock_qty
    INTO v_price, v_stock
    FROM medicines
    WHERE medicine_id = p_medicine_id
    FOR UPDATE;

    -- Check medicine existence
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Medicine does not exist';
    END IF;

    -- Check stock availability
    IF v_stock < p_quantity THEN
        RAISE EXCEPTION 'Insufficient stock';
    END IF;

    -- Record the sale using the current price
    INSERT INTO sales (
        medicine_id,
        quantity,
        unit_price,
        sold_on
    )
    VALUES (
        p_medicine_id,
        p_quantity,
        v_price,
        p_sold_on
    );

    -- Deduct stock exactly once
    UPDATE medicines
    SET stock_qty = stock_qty - p_quantity
    WHERE medicine_id = p_medicine_id;

END;
$$;

CALL pr_record_sale(1, 5, CURRENT_DATE);
CALL pr_record_sale(2, 3, CURRENT_DATE);
CALL pr_record_sale(3, 4, CURRENT_DATE);
CALL pr_record_sale(1, 2, CURRENT_DATE);
CALL pr_record_sale(2, 1, CURRENT_DATE);
CALL pr_record_sale(3, 6, CURRENT_DATE);

SELECT * FROM sales;

SELECT * FROM medicines;

CREATE OR REPLACE FUNCTION fn_stock_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    -- Audit only when stock actually changes
    IF OLD.stock_qty IS DISTINCT FROM NEW.stock_qty THEN

        INSERT INTO stock_audit (
            medicine_id,
            old_qty,
            new_qty,
            changed_at
        )
        VALUES (
            NEW.medicine_id,
            OLD.stock_qty,
            NEW.stock_qty,
            CURRENT_TIMESTAMP
        );

    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_stock_audit
AFTER UPDATE ON medicines
FOR EACH ROW
EXECUTE FUNCTION fn_stock_audit();

UPDATE medicines
SET stock_qty = stock_qty - 2
WHERE medicine_id = 1;

SELECT * FROM stock_audit;

CREATE OR REPLACE VIEW v_low_stock AS
SELECT
    medicine_name,
    unit_price,
    stock_qty AS remaining_stock
FROM medicines
WHERE stock_qty < 10;

CALL pr_record_sale(1, 90, CURRENT_DATE);

SELECT * FROM v_low_stock;

CREATE INDEX idx_sales_medicine_date
ON sales (medicine_id, sold_on);

EXPLAIN
SELECT *
FROM sales
WHERE medicine_id = 1
AND sold_on BETWEEN DATE '2026-11-01'
                AND DATE '2026-11-30';

CREATE OR REPLACE PROCEDURE pr_refresh_sales(
    p_day DATE
)
LANGUAGE plpgsql
AS $$
BEGIN
    -- Calculate and replace the totals for the selected day
    INSERT INTO daily_sales (
        sales_date,
        total_qty,
        total_amount
    )
    SELECT
        p_day,
        COALESCE(SUM(quantity), 0),
        COALESCE(SUM(quantity * unit_price), 0)
    FROM sales
    WHERE sold_on = p_day

    ON CONFLICT (sales_date)
    DO UPDATE SET
        total_qty = EXCLUDED.total_qty,
        total_amount = EXCLUDED.total_amount;

END;
$$;
ON CONFLICT (sales_date)
DO UPDATE SET
    total_qty = EXCLUDED.total_qty,
    total_amount = EXCLUDED.total_amount;
	
CALL pr_refresh_sales(CURRENT_DATE);

SELECT * FROM daily_sales;

CALL pr_refresh_sales(CURRENT_DATE);

SELECT * FROM daily_sales;

CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'refresh-daily-sales',
    '15 0 * * *',
    $$CALL pr_refresh_sales(CURRENT_DATE - 1);$$
);
