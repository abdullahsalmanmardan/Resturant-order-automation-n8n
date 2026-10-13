-- Runs once, on first start of the postgres container, against the "restaurant" database.

-- n8n keeps its own data (workflows, credentials, executions) in a separate database.
CREATE DATABASE n8n;

-- Single-row table with the restaurant's details. The bot reads it on every message.
CREATE TABLE restaurant (
    id             boolean PRIMARY KEY DEFAULT true CHECK (id),
    name           text NOT NULL,
    currency       text NOT NULL DEFAULT 'Rs',
    delivery_fee   numeric(10,2) NOT NULL DEFAULT 0,
    min_order      numeric(10,2) NOT NULL DEFAULT 0,
    opening_hours  text NOT NULL DEFAULT '',
    delivery_areas text NOT NULL DEFAULT '',
    address        text NOT NULL DEFAULT '',
    phone          text NOT NULL DEFAULT '',  -- number customers can call for complaints or changes
    payment_info   text NOT NULL DEFAULT 'Cash on delivery or at pickup',
    accepting_orders boolean NOT NULL DEFAULT true
);

CREATE TABLE menu_items (
    id          serial PRIMARY KEY,
    category    text NOT NULL,
    name        text NOT NULL,
    description text NOT NULL DEFAULT '',
    price       numeric(10,2) NOT NULL CHECK (price >= 0),
    available   boolean NOT NULL DEFAULT true,
    sort_order  integer NOT NULL DEFAULT 0
);

CREATE TABLE orders (
    id             serial PRIMARY KEY,
    customer_phone text NOT NULL,
    customer_name  text NOT NULL DEFAULT '',
    order_type     text NOT NULL CHECK (order_type IN ('delivery', 'pickup')),
    address        text NOT NULL DEFAULT '',
    notes          text NOT NULL DEFAULT '',
    language       text NOT NULL DEFAULT 'en' CHECK (language IN ('en', 'ur', 'roman_ur')),
    subtotal       numeric(10,2) NOT NULL,
    delivery_fee   numeric(10,2) NOT NULL DEFAULT 0,
    total          numeric(10,2) NOT NULL,
    status         text NOT NULL DEFAULT 'new'
                   CHECK (status IN ('new', 'accepted', 'preparing', 'ready',
                                     'out_for_delivery', 'completed', 'cancelled')),
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now()
);
-- Order numbers start at 1001 so they read like real ticket numbers.
ALTER SEQUENCE orders_id_seq RESTART WITH 1001;
CREATE INDEX orders_phone_idx ON orders (customer_phone, created_at DESC);
CREATE INDEX orders_status_idx ON orders (status, created_at DESC);

CREATE TABLE order_items (
    id           serial PRIMARY KEY,
    order_id     integer NOT NULL REFERENCES orders (id) ON DELETE CASCADE,
    menu_item_id integer NOT NULL REFERENCES menu_items (id),
    name         text NOT NULL,           -- copied at order time, so later menu edits don't rewrite history
    unit_price   numeric(10,2) NOT NULL,  -- same
    quantity     integer NOT NULL CHECK (quantity > 0),
    notes        text NOT NULL DEFAULT ''
);
CREATE INDEX order_items_order_idx ON order_items (order_id);

-- The menu and restaurant details as one block of text for the bot's system prompt.
CREATE FUNCTION bot_context() RETURNS text
LANGUAGE sql STABLE AS $$
    SELECT format(
        E'Restaurant: %s\nAddress: %s\nPhone for calls: %s\nOpening hours: %s\nDelivery areas: %s\n'
        'Payment: %s\nDelivery fee: %s %s\nMinimum order (before delivery fee): %s %s\n'
        'Currently accepting orders: %s\n\nMENU (only these items exist):\n%s',
        r.name, r.address, r.phone, r.opening_hours, r.delivery_areas, r.payment_info,
        r.currency, trim_scale(r.delivery_fee), r.currency, trim_scale(r.min_order),
        CASE WHEN r.accepting_orders THEN 'yes' ELSE 'NO' END,
        coalesce((
            SELECT string_agg(
                format('[id %s] %s | %s | %s %s%s%s',
                       m.id, m.category, m.name, r.currency, trim_scale(m.price),
                       CASE WHEN m.description <> '' THEN ' | ' || m.description ELSE '' END,
                       CASE WHEN m.available THEN '' ELSE ' | SOLD OUT TODAY' END),
                E'\n' ORDER BY m.sort_order, m.category, m.id)
            FROM menu_items m), '(menu is empty)'))
    FROM restaurant r;
$$;

-- Called by the bot's place_order tool. Prices and totals are always computed here from
-- the menu table, never taken from the AI. Returns {"ok": true, ...} or {"ok": false, "error": "..."}.
CREATE FUNCTION place_order(
    p_phone    text,
    p_name     text,
    p_type     text,
    p_address  text,
    p_items    text,   -- JSON array: [{"id": 3, "qty": 2, "notes": "no onions"}]
    p_notes    text,
    p_language text
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_rest     restaurant%ROWTYPE;
    v_items    jsonb;
    v_item     jsonb;
    v_menu     menu_items%ROWTYPE;
    v_qty      integer;
    v_subtotal numeric(10,2) := 0;
    v_fee      numeric(10,2) := 0;
    v_order_id integer;
    v_dup      orders%ROWTYPE;
    v_lines    jsonb := '[]'::jsonb;
BEGIN
    SELECT * INTO v_rest FROM restaurant;
    IF NOT v_rest.accepting_orders THEN
        RETURN jsonb_build_object('ok', false, 'error', 'The restaurant is not accepting orders right now.');
    END IF;

    p_type := lower(trim(coalesce(p_type, '')));
    IF p_type NOT IN ('delivery', 'pickup') THEN
        RETURN jsonb_build_object('ok', false, 'error', 'order_type must be "delivery" or "pickup".');
    END IF;
    p_address := trim(coalesce(p_address, ''));
    IF p_type = 'delivery' AND length(p_address) < 5 THEN
        RETURN jsonb_build_object('ok', false, 'error', 'A full delivery address is required for delivery orders.');
    END IF;
    p_language := lower(trim(coalesce(p_language, 'en')));
    IF p_language NOT IN ('en', 'ur', 'roman_ur') THEN
        p_language := 'en';
    END IF;

    BEGIN
        v_items := p_items::jsonb;
    EXCEPTION WHEN others THEN
        RETURN jsonb_build_object('ok', false, 'error', 'items is not valid JSON. Expected [{"id": 1, "qty": 2}].');
    END;
    IF v_items IS NULL OR jsonb_typeof(v_items) <> 'array' OR jsonb_array_length(v_items) = 0 THEN
        RETURN jsonb_build_object('ok', false, 'error', 'items must be a non-empty JSON array.');
    END IF;

    -- First pass: validate everything and compute the subtotal before writing anything.
    FOR v_item IN SELECT * FROM jsonb_array_elements(v_items) LOOP
        IF jsonb_typeof(v_item) <> 'object'
           OR coalesce(v_item->>'id', '') !~ '^\d{1,9}$'
           OR coalesce(v_item->>'qty', '') !~ '^\d{1,4}$' THEN
            RETURN jsonb_build_object('ok', false, 'error', 'Each item needs a numeric menu "id" and a whole-number "qty".');
        END IF;
        v_qty := (v_item->>'qty')::integer;
        IF v_qty < 1 OR v_qty > 50 THEN
            RETURN jsonb_build_object('ok', false, 'error', 'Quantity must be between 1 and 50 per item.');
        END IF;
        SELECT * INTO v_menu FROM menu_items WHERE id = (v_item->>'id')::integer;
        IF NOT FOUND THEN
            RETURN jsonb_build_object('ok', false, 'error', format('Menu item id %s does not exist.', v_item->>'id'));
        END IF;
        IF NOT v_menu.available THEN
            RETURN jsonb_build_object('ok', false, 'error', format('%s is sold out today.', v_menu.name));
        END IF;
        v_subtotal := v_subtotal + v_menu.price * v_qty;
        v_lines := v_lines || jsonb_build_object(
            'menu_item_id', v_menu.id, 'name', v_menu.name, 'unit_price', v_menu.price,
            'quantity', v_qty, 'notes', trim(coalesce(v_item->>'notes', '')));
    END LOOP;

    IF v_subtotal < v_rest.min_order THEN
        RETURN jsonb_build_object('ok', false, 'error',
            format('Minimum order is %s %s; this order is only %s %s.',
                   v_rest.currency, trim_scale(v_rest.min_order), v_rest.currency, trim_scale(v_subtotal)));
    END IF;
    IF p_type = 'delivery' THEN
        v_fee := v_rest.delivery_fee;
    END IF;

    -- If the bot calls this twice for the same confirmation, hand back the first order.
    SELECT * INTO v_dup FROM orders
     WHERE customer_phone = p_phone AND subtotal = v_subtotal AND order_type = p_type
       AND status <> 'cancelled' AND created_at > now() - interval '2 minutes'
     ORDER BY created_at DESC LIMIT 1;
    IF FOUND THEN
        RETURN jsonb_build_object('ok', true, 'duplicate', true, 'order_number', v_dup.id,
            'subtotal', v_dup.subtotal, 'delivery_fee', v_dup.delivery_fee, 'total', v_dup.total,
            'currency', v_rest.currency);
    END IF;

    INSERT INTO orders (customer_phone, customer_name, order_type, address, notes, language,
                        subtotal, delivery_fee, total)
    VALUES (p_phone, trim(coalesce(p_name, '')), p_type, p_address, trim(coalesce(p_notes, '')),
            p_language, v_subtotal, v_fee, v_subtotal + v_fee)
    RETURNING id INTO v_order_id;

    INSERT INTO order_items (order_id, menu_item_id, name, unit_price, quantity, notes)
    SELECT v_order_id, (l->>'menu_item_id')::integer, l->>'name', (l->>'unit_price')::numeric,
           (l->>'quantity')::integer, l->>'notes'
      FROM jsonb_array_elements(v_lines) l;

    RETURN jsonb_build_object('ok', true, 'order_number', v_order_id, 'items', v_lines,
        'subtotal', v_subtotal, 'delivery_fee', v_fee, 'total', v_subtotal + v_fee,
        'currency', v_rest.currency);
END;
$$;

-- Called by the bot's cancel_order tool. Customers can only cancel before the kitchen accepts.
CREATE FUNCTION cancel_order(p_phone text, p_order_number text) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_order orders%ROWTYPE;
BEGIN
    IF coalesce(p_order_number, '') !~ '^\d{1,9}$' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'order_number must be a number.');
    END IF;
    SELECT * INTO v_order FROM orders
     WHERE id = p_order_number::integer AND customer_phone = p_phone FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'error', 'No such order for this customer.');
    END IF;
    IF v_order.status = 'cancelled' THEN
        RETURN jsonb_build_object('ok', true, 'order_number', v_order.id, 'status', 'cancelled');
    END IF;
    IF v_order.status <> 'new' THEN
        RETURN jsonb_build_object('ok', false, 'error',
            format('Order is already %s and can no longer be cancelled here. Ask the customer to call the restaurant.',
                   replace(v_order.status, '_', ' ')));
    END IF;
    UPDATE orders SET status = 'cancelled', updated_at = now() WHERE id = v_order.id;
    RETURN jsonb_build_object('ok', true, 'order_number', v_order.id, 'status', 'cancelled');
END;
$$;
