const crypto = require('node:crypto');
const path = require('node:path');
const express = require('express');
const { Pool } = require('pg');

const {
  PORT = 3000,
  DATABASE_URL,
  DASHBOARD_USER = 'admin',
  DASHBOARD_PASSWORD,
  N8N_NOTIFY_URL,
  NOTIFY_SECRET = '',
  WHATSAPP_PHONE_NUMBER_ID = '',
} = process.env;

if (!DATABASE_URL || !DASHBOARD_PASSWORD) {
  console.error('DATABASE_URL and DASHBOARD_PASSWORD must be set');
  process.exit(1);
}

const pool = new Pool({ connectionString: DATABASE_URL });

// What staff can move an order to from each status; the first entry is the normal next step.
const NEXT_STATUS = {
  new: ['accepted', 'cancelled'],
  accepted: ['preparing', 'cancelled'],
  preparing: ['ready', 'cancelled'],
  out_for_delivery: ['completed', 'cancelled'],
  completed: [],
  cancelled: [],
};

function allowedNext(order) {
  if (order.status === 'ready') {
    return [order.order_type === 'delivery' ? 'out_for_delivery' : 'completed', 'cancelled'];
  }
  return NEXT_STATUS[order.status];
}

const app = express();
app.disable('x-powered-by');
app.use(express.json());

function safeEqual(a, b) {
  const ha = crypto.createHash('sha256').update(a).digest();
  const hb = crypto.createHash('sha256').update(b).digest();
  return crypto.timingSafeEqual(ha, hb);
}

app.use((req, res, next) => {
  const [scheme, encoded] = (req.headers.authorization || '').split(' ');
  if (scheme === 'Basic' && encoded) {
    const decoded = Buffer.from(encoded, 'base64').toString();
    const sep = decoded.indexOf(':');
    const user = decoded.slice(0, sep);
    const pass = decoded.slice(sep + 1);
    if (sep > -1 && safeEqual(user, DASHBOARD_USER) && safeEqual(pass, DASHBOARD_PASSWORD)) {
      return next();
    }
  }
  res.set('WWW-Authenticate', 'Basic realm="Orders"').status(401).send('Authentication required');
});

app.use(express.static(path.join(__dirname, 'public')));

// Open orders plus everything closed in the last 12 hours.
app.get('/api/orders', async (req, res) => {
  const { rows } = await pool.query(`
    SELECT o.id, o.customer_phone, o.customer_name, o.order_type, o.address, o.notes,
           o.subtotal, o.delivery_fee, o.total, o.status, o.created_at, o.updated_at,
           coalesce(json_agg(json_build_object(
               'name', i.name, 'quantity', i.quantity, 'unit_price', i.unit_price, 'notes', i.notes)
             ORDER BY i.id) FILTER (WHERE i.id IS NOT NULL), '[]') AS items
      FROM orders o
      LEFT JOIN order_items i ON i.order_id = o.id
     WHERE o.status NOT IN ('completed', 'cancelled')
        OR o.updated_at > now() - interval '12 hours'
     GROUP BY o.id
     ORDER BY o.created_at`);
  res.json(rows.map((order) => ({ ...order, next: allowedNext(order) })));
});

app.post('/api/orders/:id/status', async (req, res) => {
  const id = Number(req.params.id);
  const status = req.body?.status;
  if (!Number.isInteger(id) || typeof status !== 'string') {
    return res.status(400).json({ error: 'Invalid request' });
  }

  const client = await pool.connect();
  let order;
  try {
    await client.query('BEGIN');
    const found = await client.query('SELECT * FROM orders WHERE id = $1 FOR UPDATE', [id]);
    order = found.rows[0];
    if (!order) {
      await client.query('ROLLBACK');
      return res.status(404).json({ error: 'Order not found' });
    }
    if (!allowedNext(order).includes(status)) {
      await client.query('ROLLBACK');
      return res.status(409).json({ error: `Order is ${order.status}; cannot move it to ${status}` });
    }
    await client.query('UPDATE orders SET status = $1, updated_at = now() WHERE id = $2', [status, id]);
    await client.query('COMMIT');
  } catch (err) {
    await client.query('ROLLBACK').catch(() => {});
    throw err;
  } finally {
    client.release();
  }

  // The status is saved either way; a failed WhatsApp notification is reported, not fatal.
  const notified = await notifyCustomer(order, status);
  res.json({ ok: true, notified });
});

async function notifyCustomer(order, status) {
  if (!N8N_NOTIFY_URL) return false;
  try {
    const response = await fetch(N8N_NOTIFY_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Notify-Secret': NOTIFY_SECRET },
      body: JSON.stringify({
        phone: order.customer_phone,
        phone_number_id: WHATSAPP_PHONE_NUMBER_ID,
        order_number: order.id,
        order_type: order.order_type,
        language: order.language,
        status,
      }),
      signal: AbortSignal.timeout(10000),
    });
    if (!response.ok) console.error(`Notify webhook returned ${response.status} for order ${order.id}`);
    return response.ok;
  } catch (err) {
    console.error(`Notify webhook failed for order ${order.id}: ${err.message}`);
    return false;
  }
}

app.get('/api/menu', async (req, res) => {
  const [menu, restaurant] = await Promise.all([
    pool.query('SELECT id, category, name, price, available FROM menu_items ORDER BY sort_order, category, id'),
    pool.query('SELECT name, currency, accepting_orders FROM restaurant'),
  ]);
  res.json({ restaurant: restaurant.rows[0], items: menu.rows });
});

app.post('/api/menu/:id/available', async (req, res) => {
  const id = Number(req.params.id);
  const available = req.body?.available;
  if (!Number.isInteger(id) || typeof available !== 'boolean') {
    return res.status(400).json({ error: 'Invalid request' });
  }
  const { rowCount } = await pool.query('UPDATE menu_items SET available = $1 WHERE id = $2', [available, id]);
  if (!rowCount) return res.status(404).json({ error: 'Menu item not found' });
  res.json({ ok: true });
});

app.post('/api/restaurant/accepting', async (req, res) => {
  const accepting = req.body?.accepting;
  if (typeof accepting !== 'boolean') return res.status(400).json({ error: 'Invalid request' });
  await pool.query('UPDATE restaurant SET accepting_orders = $1', [accepting]);
  res.json({ ok: true });
});

app.use((err, req, res, next) => {
  console.error(err);
  res.status(500).json({ error: 'Server error' });
});

app.listen(PORT, () => console.log(`Dashboard listening on :${PORT}`));
