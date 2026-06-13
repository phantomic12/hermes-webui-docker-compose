#!/bin/bash
# dev-container-init.sh
# Long-lived dev-container init for the SSH backend.
#
# Replaces the image's default entrypoint (which assumes a non-root
# user and chowns /run/sshd to dev:ubuntu, breaking sshd when we
# run as root). Mounted into the container at /opt/dev-container-init.sh
# and executed as the container's main process via `command:` in compose.
#
# Does three things:
#  1. Tool auth — runs the same gh / wrangler / bw setup that the image
#     entrypoint would, if the env vars are set.
#  2. sshd setup — creates /run/sshd with correct ownership (root:root,
#     755), generates the host key if missing, and starts sshd.
#  3. Sleeps forever — compose `init: true` keeps PID 1 healthy.
set -uo pipefail

# ── Tool auth (subset of the image's default entrypoint) ──────────────
if [[ -n "${GH_TOKEN:-}" ]]; then
    echo "[sshd-init] GH_TOKEN detected — authenticating gh CLI..."
    gh auth login --hostname github.com --token "$GH_TOKEN" 2>/dev/null \
        || gh auth status || true
elif [[ -n "${GITHUB_TOKEN:-}" ]]; then
    echo "[sshd-init] GITHUB_TOKEN detected — authenticating gh CLI..."
    gh auth login --hostname github.com --token "$GITHUB_TOKEN" 2>/dev/null \
        || gh auth status || true
fi

if [[ -n "${CLOUDFLARE_API_KEY:-}" ]]; then
    echo "[sshd-init] CLOUDFLARE_API_KEY detected — configuring wrangler..."
    export CW_API_TOKEN="$CLO..."
    npx wrangler login --api-token "$CLOUDFLARE_API_KEY" 2>/dev/null \
        || npx wrangler whoami 2>/dev/null || true
fi

if [[ -n "${TAILSCALE_AUTH_KEY:-}" ]]; then
    echo "[sshd-init] TAILSCALE_AUTH_KEY detected — connecting Tailscale..."
    if ! command -v tailscale &> /dev/null; then
        curl -fsSL --retry 3 --retry-delay 5 https://tailscale.com/install.sh | sh
    fi
    # tailscaled may not be running inside the container — start it manually
    # in userspace mode (no iptables/TUN needed; container usually lacks caps)
    if ! pgrep tailscaled > /dev/null 2>&1; then
        mkdir -p /var/run/tailscale /var/cache/tailscale /var/lib/tailscale
        nohup tailscaled --tun=userspace-networking \
                         --state=/var/lib/tailscale/tailscaled.state \
                         --socket=/var/run/tailscale/tailscaled.sock >/dev/null 2>&1 &
        # Wait for socket to appear
        for i in 1 2 3 4 5 6 7 8 9 10; do
            [[ -S /var/run/tailscale/tailscaled.sock ]] && break
            sleep 1
        done
    fi
    tailscale up \
        --authkey="${TAILSCALE_AUTH_KEY}" \
        --hostname="${TAILSCALE_HOSTNAME:-dev-container}" \
        --accept-routes \
        --accept-dns=false || true
    echo "[sshd-init] Tailscale IP: $(tailscale ip -4 2>/dev/null || echo 'N/A')"
fi

# ── sshd setup with correct perms ────────────────────────────────────
mkdir -p /run/sshd
chown root:root /run/sshd
chmod 755 /run/sshd

if [[ ! -f /run/sshd/ssh_host_ed25519_key ]]; then
    ssh-keygen -t ed25519 -f /run/sshd/ssh_host_ed25519_key -N '' -C '' >/dev/null 2>&1
fi

/usr/sbin/sshd -h /run/sshd/ssh_host_ed25519_key -E /var/log/sshd.log

# sshd is strict: authorized_keys and its parent dir must be owned
# by the connecting user (root) and not group/world-writable. The bind
# mount from the host has its original ownership (yoav:yoav), so we
# chown here. Idempotent.
if [[ -d /root/.ssh ]]; then
    chown -R root:root /root/.ssh 2>/dev/null || true
    chmod 700 /root/.ssh 2>/dev/null || true
    chmod 600 /root/.ssh/authorized_keys /root/.ssh/id_ed25519 2>/dev/null || true
fi

# Drop a custom sshd_config that allows client-passed env vars.
# The agent will SendEnv GITHUB_* BW_* TAILSCALE_* BITWARDEN_*.
cat > /run/sshd/sshd_config <<'SSHD'
Port 22
HostKey /run/sshd/ssh_host_ed25519_key
PidFile /run/sshd/sshd.pid
PermitRootLogin yes
PubkeyAuthentication yes
PasswordAuthentication no
AuthorizedKeysFile /root/.ssh/authorized_keys
AcceptEnv LANG LC_* GITHUB_* BW_* TAILSCALE_* BITWARDEN_* CLOUDFLARE_*
SSHD

# Restart sshd with the new config (it was started above with defaults;
# kill it and re-start with -f)
pkill sshd 2>/dev/null || true
sleep 1
/usr/sbin/sshd -f /run/sshd/sshd_config -E /var/log/sshd.log

echo "[sshd-init] sshd listening on port 22 (with env forwarding)"

exec sleep infinity
