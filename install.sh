#!/usr/bin/env bash
# install.sh — Run this on the Ubuntu 22.04 Azure VM as a regular (non-root) user.
# Usage: bash install.sh [--skip-node] [--skip-pool] [--skip-explorer] [--skip-nginx]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Load user config ──────────────────────────────────────────────────────────
if [ ! -f "$SCRIPT_DIR/vars.sh" ]; then
    echo "ERROR: vars.sh not found. Copy it from the repo and fill in your values."
    exit 1
fi
# shellcheck source=vars.sh
source "$SCRIPT_DIR/vars.sh"

# Sanity checks
if [[ "$RPC_PASS" == "CHANGE_ME_STRONG_PASSWORD" ]]; then
    echo "ERROR: Edit vars.sh and set a real RPC_PASS before running."
    exit 1
fi
if [[ "$POOL_WALLET_ADDRESS" == "CHANGE_ME_YOUR_DEFCOIN_ADDRESS" ]]; then
    echo "ERROR: Edit vars.sh and set your POOL_WALLET_ADDRESS before running."
    exit 1
fi

# ── Parse flags ───────────────────────────────────────────────────────────────
SKIP_NODE=false; SKIP_POOL=false; SKIP_EXPLORER=false; SKIP_NGINX=false
for arg in "$@"; do
    case "$arg" in
        --skip-node)     SKIP_NODE=true ;;
        --skip-pool)     SKIP_POOL=true ;;
        --skip-explorer) SKIP_EXPLORER=true ;;
        --skip-nginx)    SKIP_NGINX=true ;;
    esac
done

# ── System prep ───────────────────────────────────────────────────────────────
echo "=== Updating apt packages ==="
sudo apt-get update -qq

# ── Create dedicated service user ─────────────────────────────────────────────
if ! id defcoin &>/dev/null; then
    sudo useradd -r -m -d /var/lib/defcoin -s /usr/sbin/nologin defcoin
    echo "Created system user 'defcoin'"
fi

# Make sure the current user can write to /opt dirs (scripts chown them)
export POOL_DIR EXPLORER_DIR DEFCOIN_DIR RPC_USER RPC_PASS \
       POOL_WALLET_ADDRESS POOL_DOMAIN EXPLORER_DOMAIN CERTBOT_EMAIL

# ── Phase 2: defcoin node ─────────────────────────────────────────────────────
if [ "$SKIP_NODE" = false ]; then
    bash "$SCRIPT_DIR/01-build-node.sh"

    # Copy configs to the service user's data dir
    sudo mkdir -p /var/lib/defcoin
    sudo cp "$HOME/.defcoin/defcoin.conf" /var/lib/defcoin/defcoin.conf
    sudo chown -R defcoin:defcoin /var/lib/defcoin
    sudo chmod 700 /var/lib/defcoin
    sudo chmod 600 /var/lib/defcoin/defcoin.conf
fi

# ── Phase 3: mining pool ──────────────────────────────────────────────────────
if [ "$SKIP_POOL" = false ]; then
    bash "$SCRIPT_DIR/02-setup-pool.sh"
    sudo chown -R defcoin:defcoin "$POOL_DIR"
fi

# ── Phase 4: block explorer ───────────────────────────────────────────────────
if [ "$SKIP_EXPLORER" = false ]; then
    bash "$SCRIPT_DIR/03-setup-explorer.sh"
    sudo chown -R defcoin:defcoin "$EXPLORER_DIR"
fi

# ── Phase 5: nginx + SSL ──────────────────────────────────────────────────────
if [ "$SKIP_NGINX" = false ]; then
    bash "$SCRIPT_DIR/04-setup-nginx.sh"
fi

# ── Phase 6: systemd services ─────────────────────────────────────────────────
echo "=== Installing systemd services ==="
for svc in defcoind defcoin-pool defcoin-explorer defcoin-sync; do
    sudo cp "$SCRIPT_DIR/systemd/${svc}.service" /etc/systemd/system/
done

sudo systemctl daemon-reload
sudo systemctl enable defcoind defcoin-pool defcoin-explorer defcoin-sync

echo ""
echo "========================================================"
echo " INSTALLATION COMPLETE"
echo "========================================================"
echo ""
echo "Start the node first and let it sync before starting the pool and explorer:"
echo ""
echo "  sudo systemctl start defcoind"
echo "  defcoin-cli -datadir=/var/lib/defcoin getblockchaininfo"
echo ""
echo "Once synced (blocks = network height), start everything:"
echo ""
echo "  sudo systemctl start defcoin-pool defcoin-explorer defcoin-sync"
echo ""
echo "Check logs:"
echo "  journalctl -u defcoind -f"
echo "  journalctl -u defcoin-pool -f"
echo "  journalctl -u defcoin-explorer -f"
echo ""
echo "CRITICAL: If 'defcoin-cli -datadir=/var/lib/defcoin getpeerinfo' returns []"
echo "after a few minutes, the DNS seeders are dead. Get live peer IPs from"
echo "defcoin.host and add them to /var/lib/defcoin/defcoin.conf:"
echo "  addnode=<peer-ip>"
echo "Then: sudo systemctl restart defcoind"
echo ""
echo "Explorer:  https://${EXPLORER_DOMAIN}"
echo "Pool:      https://${POOL_DOMAIN}"
echo "Stratum:   stratum+tcp://${POOL_DOMAIN}:3333"
