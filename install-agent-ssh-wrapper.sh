#!/bin/bash
# install-agent-ssh-wrapper.sh
# Copies the agent's SSH client wrapper into the data volume and
# makes sure it's executable. Idempotent — safe to re-run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER_SRC="$SCRIPT_DIR/agent-ssh-wrapper.sh"
WRAPPER_DST_DIR="/home/yoav/hermes/data/bin"
WRAPPER_DST="$WRAPPER_DST_DIR/ssh"

mkdir -p "$WRAPPER_DST_DIR"
cp "$WRAPPER_SRC" "$WRAPPER_DST"
chmod 755 "$WRAPPER_DST"
echo "Installed: $WRAPPER_DST"
