#!/bin/sh
# Runs INSIDE the n8n container (scripts/setup.sh calls it). Creates the credentials from the
# values in .env and imports the workflows from ./workflows.
set -eu

umask 077
CREDS_FILE=$(mktemp)
trap 'rm -f "$CREDS_FILE"' EXIT

node -e '
const e = process.env;
const creds = [
  { id: "credWaTrigger0001", name: "WhatsApp Trigger (Meta app)", type: "whatsAppTriggerApi",
    data: { clientId: e.META_APP_ID || "", clientSecret: e.META_APP_SECRET || "" } },
  { id: "credWaSend0000001", name: "WhatsApp Cloud API", type: "whatsAppApi",
    data: { accessToken: e.WHATSAPP_ACCESS_TOKEN || "", businessAccountId: e.WHATSAPP_BUSINESS_ACCOUNT_ID || "" } },
  { id: "credAnthropic0001", name: "Anthropic", type: "anthropicApi",
    data: { apiKey: e.ANTHROPIC_API_KEY || "" } },
  { id: "credPostgres00001", name: "Restaurant DB", type: "postgres",
    data: { host: "postgres", port: 5432, database: "restaurant", user: "restaurant",
            password: e.POSTGRES_PASSWORD, ssl: "disable" } },
  { id: "credNotifyHdr0001", name: "Dashboard notify secret", type: "httpHeaderAuth",
    data: { name: "X-Notify-Secret", value: e.NOTIFY_SECRET } },
];
require("fs").writeFileSync(process.argv[1], JSON.stringify(creds));
' "$CREDS_FILE"

echo "Importing credentials..."
n8n import:credentials --input="$CREDS_FILE"

# Workflows are only imported when missing, so edits made in the n8n editor are never overwritten.
# Pass --force to replace them with the files from ./workflows.
EXISTING=$(n8n list:workflow 2>/dev/null || true)
for file in /import/workflows/*.json; do
  id=$(node -p 'require(process.argv[1]).id' "$file")
  if [ "${1:-}" != "--force" ] && echo "$EXISTING" | grep -q "^$id|"; then
    echo "Workflow $(basename "$file") already exists, leaving it alone."
  else
    echo "Importing workflow $(basename "$file")..."
    n8n import:workflow --input="$file"
  fi
done
