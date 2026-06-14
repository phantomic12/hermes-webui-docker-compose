#!/bin/bash
# /opt/data/bin/ssh — wrapper for the OpenSSH client.
#
# Why this exists: OpenSSH refuses to read config files that aren't
# owned by the user running ssh. The agent's bind-mounted config
# (/etc/ssh/ssh_config.d/agent.conf) is owned by the host's yoav user
# (uid 1000), but the agent's ssh runs as root. Even with :rw mounts
# and the agent command override, Docker doesn't grant CAP_CHOWN
# across bind-mount boundaries, so we can't chown the file from
# inside the container.
#
# Workaround: this wrapper intercepts the ssh invocation, parses the
# -F flag if present (so we know if the user explicitly chose a
# different config), and forwards the call to the real ssh binary
# (/usr/bin/ssh) with the SendEnv flags injected via -o.
#
# This file lives on the agent's data volume (./data/bin/ssh on the
# host, /opt/data/bin/ssh in the agent container) and is made the
# first entry on PATH via the agent's `environment:` block in compose.
#
# To update the env-var patterns, edit the PREFIX array below.

REAL_SSH=/usr/bin/ssh

# Check if the user passed an explicit -F; if so, respect it.
# Otherwise, force -F /dev/null to skip the broken
# /etc/ssh/ssh_config.d/agent.conf include (whose ownership is wrong).
HAS_F=0
for arg in "$@"; do
    if [[ "$arg" == "-F" ]]; then
        HAS_F=1
        break
    fi
done

# Inject SendEnv for known variable patterns. Add new patterns here.
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

exec "$REAL_SSH" "${PREFIX[@]}" "$@"
