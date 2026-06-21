#!/usr/bin/env bash
# whatsapp-link.sh <brain> - link (or relink) WhatsApp for a brain the RIGHT way.
#
# Runs the pairing inside the brain's container in a real TTY, so you scan a
# LIVE, auto-refreshing QR. Do NOT ask the chat agent to "print the QR": the QR
# rotates every ~20s, so a relayed one is already expired and WhatsApp says
# "couldn't link device."
#
# The phone you scan with becomes the AGENT (it receives messages and replies).
# Set who may message it via WHATSAPP_MODE / WHATSAPP_ALLOWED_USERS in the brain
# .env first. See README, "Linking WhatsApp".
set -euo pipefail

NAME="${1:-}"
[[ -z "$NAME" ]] && { echo "usage: ./lib/whatsapp-link.sh <brain-name>" >&2; exit 1; }

if ! docker ps --format '{{.Names}}' | grep -qx "$NAME"; then
  echo "error: container '$NAME' is not running." >&2
  echo "       start it:  cd ~/homelab/$NAME && docker compose up -d" >&2
  exit 1
fi

echo "Linking WhatsApp for '$NAME'."
echo "Scan the QR below with the phone that should BE the bot (the agent number)."
echo
echo "Over SSH and the terminal QR won't scan? Open this PNG instead. The bridge"
echo "rewrites it on every refresh, so it is always the current code:"
echo "  ~/homelab/$NAME/data/whatsapp/session/latest-qr.png"
echo

exec docker exec -it "$NAME" hermes whatsapp
