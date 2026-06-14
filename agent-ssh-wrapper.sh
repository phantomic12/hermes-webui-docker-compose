#!/bin/bash
# /opt/data/bin/ssh — wrapper for the OpenSSH client.
#
# Why this exists:
#   1. OpenSSH refuses to read config files not owned by the running
#      user. The bind-mounted config file approach didn't work because
#      of the host/container ownership mismatch.
#   2. The agent's terminal backend runs as the `hermes` user (uid
#      10000), but the yoav private key is bind-mounted from the host
#      and owned by the host's `yoav` user (uid 1000). ssh refuses
#      to load keys that the calling user can't read.
#
# Workaround:
#   - Inject SendEnv flags directly via -o (skipping the broken
#     /etc/ssh/ssh_config.d/ include).
#   - Stage a copy of the key into a hermes-owned directory and use
#     that path. Idempotent — re-runs are cheap.

set -uo pipefail

REAL_SSH=/usr/bin/ssh
KEY_SRC="/opt/data/yoav"
KEY_STAGE_DIR="/opt/data/.ssh-staged"
KEY_STAGE="$KEY_STAGE_DIR/yoav"

# Stage the key with hermes-friendly ownership on first use
if [[ -f "$KEY_SRC" ]]; then
    mkdir -p "$KEY_STAGE_DIR"
    cp -f "$KEY_SRC" "$KEY_STAGE" 2>/dev/null || true
    chmod 600 "$KEY_STAGE" 2>/dev/null || true
fi

# Detect explicit -F (user chose their own config) so we don't override
HAS_F=0
for arg in "$@"; do
    if [[ "$arg" == "-F" ]]; then
        HAS_F=1
        break
    fi
done

# Build the prefix: inject SendEnv for known patterns, plus -F /dev/null
# to skip the broken /etc/ssh/ssh_config.d/agent.conf include.
PREFIX=(
    -o "SendEnv=GITHUB_*"
    -o "SendEnv=BW_*"
    -o "SendEnv=TAILSCALE_*"
    -o "SendEnv=BITWARDEN_*"
    -o "SendEnv=CLOUDFLARE_*"
)
if [[ $HAS_F -eq 0 ]]; then
    PREFIX+=("-F" "/dev/null")
fi

# If the user passed -i /opt/data/yoav, swap to our staged copy
ARGS=("$@")
for i in "${!ARGS[@]}"; do
    if [[ "${ARGS[$i]}" == "-i" ]] && [[ "${ARGS[$((i+1))]:-}" == "/opt/data/yoav" ]]; then
        ARGS[$((i+1))]="$KEY_STAGE"
        break
    fi
done

exec "$REAL_SSH" "${PREFIX[@]}" "${ARGS[@]}"
