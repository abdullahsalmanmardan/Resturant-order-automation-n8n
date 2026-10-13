#!/usr/bin/env bash
# One-command install: creates .env with random secrets, starts the stack, and loads the
# credentials and workflows into n8n. Safe to run again after editing .env.
#   scripts/setup.sh           keep workflows already in n8n
#   scripts/setup.sh --force   replace the n8n workflows with the files in ./workflows
set -euo pipefail
cd "$(dirname "$0")/.."

random() { openssl rand -hex "$1"; }

if [ ! -f .env ]; then
  cp .env.example .env
  chmod 600 .env
  sed -i.bak \
    -e "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$(random 16)|" \
    -e "s|^N8N_ENCRYPTION_KEY=.*|N8N_ENCRYPTION_KEY=$(random 24)|" \
    -e "s|^NOTIFY_SECRET=.*|NOTIFY_SECRET=$(random 24)|" \
    -e "s|^DASHBOARD_PASSWORD=.*|DASHBOARD_PASSWORD=$(random 8)|" \
    .env
  rm -f .env.bak
  echo "Created .env with fresh secrets."
fi

docker compose up -d --build --wait

docker compose exec -T n8n sh /import/import-into-n8n.sh "${1:-}"

set -a; . ./.env; set +a
missing=()
for var in ANTHROPIC_API_KEY WHATSAPP_ACCESS_TOKEN WHATSAPP_BUSINESS_ACCOUNT_ID WHATSAPP_PHONE_NUMBER_ID META_APP_ID META_APP_SECRET PUBLIC_URL; do
  [ -n "${!var:-}" ] || missing+=("$var")
done

cat <<EOF

Done.
  n8n editor : http://localhost:${N8N_HOST_PORT:-5678}
  Dashboard  : http://localhost:${DASHBOARD_HOST_PORT:-3000}   (user: ${DASHBOARD_USER:-admin}, password: in .env)
EOF
if [ ${#missing[@]} -gt 0 ]; then
  echo
  echo "Still empty in .env: ${missing[*]}"
  echo "Fill them in (see README), then run scripts/setup.sh again."
else
  echo
  echo "Next: open the n8n editor and publish both workflows (README, step 4)."
fi
