#!/usr/bin/env bash
# new-brain.sh <name>  — scaffold ONE isolated, fully-featured Hermes brain.
#
# Reuses the hermes-wa:local image (build-image.sh makes it), then layers on:
#   - the seed/ feature bundle (skills, bin tools, scripts, cron, fonts, assets)
#   - config.template.yaml (image-analysis, whisper transcription, MCP, etc.)
#   - a fresh SOUL.md identity for THIS brain (never a copy of another)
#
# Isolation: own folder, own data volume, own container, own .env, own CLI
# wrapper. Each brain gets fresh memory/sessions; only the FEATURES are shared.
set -euo pipefail

NAME="${1:-}"
if [[ -z "$NAME" ]]; then echo "usage: new-brain.sh <name>" >&2; exit 1; fi
if [[ ! "$NAME" =~ ^[a-z][a-z0-9-]{1,30}$ ]]; then
  echo "error: name must be lowercase [a-z0-9-], start with a letter, 2-31 chars. got: '$NAME'" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
HOMELAB="${HOMELAB:-$HOME/homelab}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
DIR="$HOMELAB/$NAME"
WRAPPER="$BIN_DIR/$NAME"
IMAGE="${IMAGE:-hermes-wa:local}"
MEM="${MEM:-2g}"
CPUS="${CPUS:-2.0}"

[[ -e "$DIR" ]]      && { echo "error: $DIR already exists." >&2; exit 1; }
[[ -e "$WRAPPER" ]]  && { echo "error: $WRAPPER already exists (name taken on PATH)." >&2; exit 1; }
docker ps -a --format '{{.Names}}' | grep -qx "$NAME" && { echo "error: container '$NAME' exists. docker rm -f $NAME" >&2; exit 1; }
docker image inspect "$IMAGE" >/dev/null 2>&1 || { echo "error: image $IMAGE missing. Run lib/build-image.sh first." >&2; exit 1; }

echo "==> [$NAME] creating $DIR/data and seeding features"
mkdir -p "$DIR/data" "$BIN_DIR"
cp -a "$REPO_ROOT/seed/." "$DIR/data/"
cp "$REPO_ROOT/templates/config.template.yaml" "$DIR/data/config.yaml"
sed "s/{{BRAIN_NAME}}/$NAME/g" "$REPO_ROOT/templates/SOUL.template.md" > "$DIR/data/SOUL.md"

echo "==> [$NAME] writing compose + env"
sed -e "s/__NAME__/$NAME/g" -e "s/__MEM__/$MEM/g" -e "s/__CPUS__/$CPUS/g" \
  "$REPO_ROOT/templates/docker-compose.template.yml" > "$DIR/docker-compose.yml"
cp "$REPO_ROOT/templates/env.example" "$DIR/.env"
chmod 600 "$DIR/.env"

echo "==> [$NAME] writing CLI wrapper -> $WRAPPER"
cat > "$WRAPPER" <<EOF
#!/usr/bin/env bash
# CLI for the dockerized Hermes brain "$NAME". Auto-starts the container,
# runs the one-time setup wizard on first launch, then routes the hermes CLI.
set -euo pipefail
CONTAINER=$NAME
COMPOSE_DIR=$DIR
# Run a command in the brain, attaching a TTY only when we have one
# (interactive wizards / the WhatsApp QR need -it; pipes and cron need -i).
dx() { if [ -t 0 ] && [ -t 1 ]; then docker exec -it "\$CONTAINER" "\$@"; else docker exec -i "\$CONTAINER" "\$@"; fi; }
if ! docker ps --format '{{.Names}}' | grep -qx "\$CONTAINER"; then
  (cd "\$COMPOSE_DIR" && docker compose up -d) >&2
fi
if ! docker exec "\$CONTAINER" test -f /opt/data/.configured; then
  echo "[$NAME] first run: launching 'hermes setup' (provider + key + model)..." >&2
  dx hermes setup
  docker exec "\$CONTAINER" touch /opt/data/.configured
fi
# WhatsApp: after pairing the bot still won't reply unless the gateway is
# running. The gateway ships "down" and 'hermes whatsapp' does not start it,
# so run the link, then bring the gateway online. stop+start works whether it
# was up or down and reconnects the freshly-linked session.
if [ "\${1:-}" = whatsapp ]; then
  dx hermes whatsapp
  echo "[$NAME] bringing the gateway online so the bot replies..." >&2
  docker exec "\$CONTAINER" hermes gateway stop  >/dev/null 2>&1 || true
  docker exec "\$CONTAINER" hermes gateway start >/dev/null 2>&1 || true
  docker exec "\$CONTAINER" hermes gateway status 2>&1 | head -2
  exit 0
fi
[ \$# -eq 0 ] && set -- chat
dx hermes "\$@"
EOF
chmod +x "$WRAPPER"

echo "==> [$NAME] starting container"
( cd "$DIR" && docker compose up -d >/dev/null )

# Bind-mounted seed files land owned by the host user; the in-container
# hermes account is uid/gid 1001. Without this chown the brain cannot write
# its own state dir (sessions, memory, logs). Classic Hermes uid-mismatch gotcha.
echo "==> [$NAME] fixing /opt/data ownership to hermes (1001:1001)"
docker exec -u 0 "$NAME" chown -R hermes:hermes /opt/data

# Same uid-mismatch class, different dir. The upstream image ships JS helper
# dirs under /opt/hermes/scripts (e.g. whatsapp-bridge) owned by the build user
# (uid 10000), but the runtime drops to hermes (1001). Those dirs lazily run
# `npm install` into their own node_modules on first use - `<brain> whatsapp`
# linking is the common trigger - which fails EACCES without write access.
# Chown every scripts dir that has a package.json so first-run installs work.
echo "==> [$NAME] fixing /opt/hermes/scripts npm-helper ownership (whatsapp-bridge etc.)"
docker exec -u 0 "$NAME" sh -c \
  'find /opt/hermes/scripts -maxdepth 2 -name package.json -printf "%h\0" | xargs -0 -r chown -R hermes:hermes' \
  || echo "    (no npm-helper dirs to fix, or chown skipped)"

cat <<EOF

==========================================
 $NAME ready  (fully featured)
==========================================
 folder:    $DIR
 container: $NAME        ($MEM RAM, $CPUS CPU)
 CLI:       $NAME        (run from anywhere; '$NAME' alone opens chat)
 skills:    $(ls "$DIR/data/skills" | wc -l | tr -d ' ') seeded (finance, media, research, ...)

 next:
  1. edit $DIR/.env          -> add ONE provider key (and APIFY_TOKEN for MCP)
  2. run:  $NAME                  -> first run does the setup wizard, then chat
  3. edit $DIR/data/SOUL.md   -> give this brain its real role + voice
  4. WhatsApp? set WHATSAPP_MODE / WHATSAPP_ALLOWED_USERS in .env, then run
       $NAME whatsapp           -> scan the LIVE QR (see README: Linking WhatsApp)
       NOT via the chat agent - it relays an expired QR. Scan in a real terminal.
EOF
