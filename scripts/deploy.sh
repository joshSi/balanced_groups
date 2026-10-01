#!/usr/bin/env sh
# Build the API server in ReleaseSafe and (re)install it as a systemd service.
# Idempotent: safe to re-run after every code change.
#
#   sudo ./scripts/deploy.sh
set -eu

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR=/opt/balanced-groups
ENV_FILE=/etc/balanced-groups.env
UNIT=balanced-groups

cd "$REPO"
echo "==> building (ReleaseSafe)"
zig build -Doptimize=ReleaseSafe

echo "==> installing binary to $BIN_DIR"
install -d "$BIN_DIR"
install -m 755 zig-out/bin/balanced-groups-server "$BIN_DIR/balanced-groups-server.new"
mv -f "$BIN_DIR/balanced-groups-server.new" "$BIN_DIR/balanced-groups-server"

if [ ! -f "$ENV_FILE" ]; then
    echo "==> creating $ENV_FILE with a fresh API key"
    KEY="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    sed "s/^BG_API_KEY=.*/BG_API_KEY=$KEY/" deploy/balanced-groups.env.example > "$ENV_FILE"
    chmod 600 "$ENV_FILE"
else
    echo "==> keeping existing $ENV_FILE"
fi

echo "==> installing systemd unit"
install -m 644 deploy/balanced-groups.service "/etc/systemd/system/$UNIT.service"
systemctl daemon-reload
systemctl enable "$UNIT" >/dev/null 2>&1 || true
systemctl restart "$UNIT"

PORT="$(sed -n 's/^BG_PORT=//p' "$ENV_FILE")"
sleep 1
if curl -fsS "http://127.0.0.1:${PORT:-8090}/healthz" >/dev/null; then
    echo "==> $UNIT is up on 127.0.0.1:${PORT:-8090}"
else
    echo "!! health check failed; see: journalctl -u $UNIT -n 50 --no-pager" >&2
    exit 1
fi
