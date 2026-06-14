#!/bin/bash
# install-agent-init.sh
# First-run setup for the agent container:
#   - Stages the yoav private key into a hermes-owned location
#     (/opt/data/.ssh/yoav) so the gateway (running as hermes,
#     uid 10000) can read it for SSH to the dev-container.
#   - The bind-mounted /opt/data/yoav stays at uid 1000 (host
#     yoav) — too restrictive for the gateway's runtime user.
#
# Idempotent — safe to re-run.
set -euo pipefail

# Must run as root (or have CAP_CHOWN) since we're staging into
# a hermes-owned directory.
if [[ $EUID -ne 0 ]]; then
    echo "Must run as root (use docker exec -u 0 ...)"
    exit 1
fi

HERMES_UID=10000
HERMES_GID=10000
KEY_SRC=/opt/data/yoav
KEY_DST_DIR=/opt/data/.ssh
KEY_DST=$KEY_DST_DIR/yoav

if [[ ! -f "$KEY_SRC" ]]; then
    echo "Source key not found: $KEY_SRC"
    exit 1
fi

mkdir -p "$KEY_DST_DIR"
chown "$HERMES_UID:$HERMES_GID" "$KEY_DST_DIR"
chmod 700 "$KEY_DST_DIR"

cp -f "$KEY_SRC" "$KEY_DST"
chown "$HERMES_UID:$HERMES_GID" "$KEY_DST"
chmod 600 "$KEY_DST"

echo "Installed: $KEY_DST (uid=$HERMES_UID)"
