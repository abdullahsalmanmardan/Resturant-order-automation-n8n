# WhatsApp restaurant ordering bot (n8n)

Customers message the restaurant on WhatsApp. An AI agent (Claude) answers in English, Urdu or
Roman Urdu, takes the order, and saves it. Staff see it on a kitchen dashboard and move it through
its statuses; the customer gets a WhatsApp update at each step.

```
Customer ──WhatsApp──► n8n "WhatsApp Order Bot" ──► Postgres (menu, orders)
                         (AI agent + tools)              ▲
                                                         │
Customer ◄─WhatsApp── n8n "Order Status Notifications" ◄─┴─ Kitchen dashboard (staff)
```

| Folder | What it is |
| --- | --- |
| `workflows/` | The two n8n workflows, imported automatically |
| `db/` | Database tables, the ordering logic (`place_order`), and the sample menu |
| `dashboard/` | Kitchen dashboard (small Node app) |
| `scripts/` | Install script |

Prices and totals are always calculated in the database from the menu table. The AI only chooses
item ids and quantities, so it cannot invent a price or a discount.

## Setup

You need Docker Desktop, an Anthropic API key, and a Meta developer account.

### 1. Start everything

```sh
./scripts/setup.sh
```

This creates `.env` with random passwords, starts Postgres, n8n and the dashboard, and loads the
workflows and credentials into n8n.

- n8n editor: http://localhost:5678 (create your owner account on first visit; do this before
  step 3, because the tunnel makes this page reachable from the internet)
- Dashboard: http://localhost:3000 (user `admin`, password is `DASHBOARD_PASSWORD` in `.env`)

### 2. Put in your restaurant and menu

The database starts with a sample restaurant and menu from `db/02-seed.sql`. Change them with SQL:

```sh
docker compose exec postgres psql -U restaurant -d restaurant
```

```sql
UPDATE restaurant SET name = 'My Restaurant', phone = '0300-1234567', delivery_fee = 200,
       min_order = 800, opening_hours = 'Daily 1 pm to 1 am', delivery_areas = 'DHA, Gulberg';

INSERT INTO menu_items (category, name, description, price, sort_order)
VALUES ('BBQ', 'Reshmi Kabab (4 pcs)', '', 700, 23);
UPDATE menu_items SET price = 500 WHERE name = 'Chicken Biryani';
DELETE FROM menu_items WHERE name = 'Beef Pulao';  -- only works if it was never ordered
```

The bot reads the menu fresh on every message, so changes apply immediately. Marking an item sold
out for the day is done from the dashboard's **Menu** tab instead.

### 3. Connect WhatsApp

1. Get a public HTTPS address that forwards to `localhost:5678`. For testing, ngrok with a free
   static domain works: `ngrok http --url=YOUR-NAME.ngrok-free.app 5678`. Put the address in
   `.env` as `PUBLIC_URL=https://YOUR-NAME.ngrok-free.app`.
2. At https://developers.facebook.com create an app (type **Business**) and add the **WhatsApp**
   product. From **WhatsApp → API Setup** copy into `.env`:
   - `WHATSAPP_PHONE_NUMBER_ID`
   - `WHATSAPP_BUSINESS_ACCOUNT_ID`
   - `WHATSAPP_ACCESS_TOKEN` (the token on that page expires after 24 hours; for real use, create
     a System User token in Meta Business Settings with the `whatsapp_business_messaging` and
     `whatsapp_business_management` permissions)
3. From **App settings → Basic** copy `META_APP_ID` and `META_APP_SECRET`.
4. Add `ANTHROPIC_API_KEY` to `.env`.
5. Run `./scripts/setup.sh` again. It updates the credentials in n8n and leaves your workflows alone.

Meta gives every app a free test number. It can only message phone numbers you have added under
**API Setup → To**, so add your own phone there first.

### 4. Publish the workflows

In the n8n editor open **WhatsApp Order Bot** and **Order Status Notifications** and publish each
one (button at the top right). Publishing the order bot registers the webhook with Meta; if the
Meta details are wrong, n8n shows the error at this point.

Now send "hi" or "menu dikha dein" to the WhatsApp number.

## Day to day

- **Orders tab**: new orders appear within 5 seconds with a beep. Buttons move an order through
  Accept → Start preparing → Mark ready → Out for delivery / Complete. Cancel is available until
  the order is closed.
- **Menu tab**: untick sold-out items, or switch off "Accepting orders" to pause the bot.
- Customers hear about: accepted, ready (pickup only), out for delivery, and cancelled. Change the
  wording or the list in the **Build Message** node of the notifications workflow.
- Customers can cancel through the bot only while the order is still **New**.

## Changing the bot

- Tone, rules, upselling: **AI Agent → Options → System Message** in the order bot workflow.
- Model: **Anthropic Chat Model** node (set to `claude-sonnet-5-5`).
- After editing in n8n, export the workflow (⋯ → Download) into `workflows/` to keep the files
  in this folder up to date. `./scripts/setup.sh --force` does the opposite: it replaces the
  workflows in n8n with these files.

## Good to know

- WhatsApp only allows free-form messages within 24 hours of the customer's last message. Status
  updates for an order placed minutes ago are fine; messaging a customer the next day needs an
  approved template.
- Voice notes, photos and locations are not understood yet; the bot asks for text.
- Conversation memory is per customer per day (resets at 5 am).
- Payment is cash only as written. The `payment_info` column in `restaurant` is what the bot tells
  customers.
- A Meta app has one webhook address. Using "Execute workflow" on the WhatsApp Trigger in the
  editor points Meta at n8n's test address; publish the workflow again afterwards.
- To move to a server: copy this folder, set `PUBLIC_URL` to your domain (with HTTPS in front of
  port 5678), and run `./scripts/setup.sh`. Keep `.env` safe: `N8N_ENCRYPTION_KEY` is needed to
  read the saved credentials.

## Useful commands

```sh
docker compose logs -f n8n          # watch n8n
docker compose down                 # stop (data is kept)
docker compose down -v              # stop and DELETE all data, including orders
```
