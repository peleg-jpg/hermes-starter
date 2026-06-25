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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOMELAB="${HOMELAB:-$HOME/homelab}"
ENV_FILE="$HOMELAB/$NAME/.env"

if ! docker ps --format '{{.Names}}' | grep -qx "$NAME"; then
  echo "error: container '$NAME' is not running." >&2
  echo "       start it:  cd ~/homelab/$NAME && docker compose up -d" >&2
  exit 1
fi

# Guard 1 - empty WHATSAPP_ALLOWED_USERS means the bot accepts ZERO messages.
# This is the #1 "I linked it but it never replies" trap: the QR scans fine,
# then every inbound is silently dropped. Warn loudly BEFORE we link so the
# operator doesn't blame the QR and re-scan in a loop. (We read the value with
# a grep, not by sourcing - the .env may contain anything.)
if [[ -f "$ENV_FILE" ]]; then
  allowed="$(grep -E '^WHATSAPP_ALLOWED_USERS=' "$ENV_FILE" | tail -n1 | cut -d= -f2- | tr -d '[:space:]')"
  mode="$(grep -E '^WHATSAPP_MODE=' "$ENV_FILE" | tail -n1 | cut -d= -f2- | tr -d '[:space:]')"
  if [[ -z "$allowed" ]]; then
    echo "WARNING: WHATSAPP_ALLOWED_USERS is empty in $ENV_FILE." >&2
    echo "         The bot will accept ZERO messages (secure default) - linking" >&2
    echo "         succeeds but every inbound is silently dropped. Set the" >&2
    echo "         SENDER's number(s) (country code, no '+'), then re-run:" >&2
    echo "             WHATSAPP_ALLOWED_USERS=972501234567   ('*' = everyone)" >&2
    echo >&2
  fi
  if [[ "$mode" == "self-chat" ]]; then
    echo "NOTE: WHATSAPP_MODE=self-chat - the bot only answers your own" >&2
    echo "      'Note to Self' chat, not messages from other people." >&2
    echo >&2
  fi
fi

# Guard 2 - confirm the gateway noise patches are still applied. They get wiped
# by a container recreate/rebuild, so a relinked brain can be loud again with no
# signal. Report-only (never blocks linking); points at the fix if missing.
if [[ -x "$SCRIPT_DIR/check-patches.sh" ]]; then
  "$SCRIPT_DIR/check-patches.sh" "$NAME" >/dev/null 2>&1 || {
    echo "WARNING: [$NAME] WhatsApp gateway noise patches are MISSING." >&2
    echo "         WhatsApp may post English play-by-play. Fix with:" >&2
    echo "             ./lib/patch-gateway.sh $NAME" >&2
    echo >&2
  }
fi

echo "Linking WhatsApp for '$NAME'."
echo "Scan the QR below with the phone that should BE the bot (the agent number)."
echo
echo "Over SSH and the terminal QR won't scan? Open this PNG instead. The bridge"
echo "rewrites it on every refresh, so it is always the current code:"
echo "  ~/homelab/$NAME/data/whatsapp/session/latest-qr.png"
echo

exec docker exec -it "$NAME" hermes whatsapp
