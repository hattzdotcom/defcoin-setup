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
if [[ "$ADMIN_PASS" == "CHANGE_ME_ADMIN_PASS" ]]; then
    echo "ERROR: Edit vars.sh and set a real ADMIN_PASS before running."
    exit 1
fi
# RPC_PASS and ADMIN_PASS get embedded both in defcoin.conf (INI: '#' starts
# a comment, '=' ends the key) and in pool_configs/defcoin.json, config.json,
# settings.json (JSON: '"' and '\' break out of the string literal). A
# password containing any of those characters silently corrupts whichever
# config it lands in rather than failing loudly, so reject them up front.
for pw_name in RPC_PASS ADMIN_PASS; do
    pw_val="${!pw_name}"
    if [[ "$pw_val" == *'"'* || "$pw_val" == *'\'* || "$pw_val" == *'#'* || "$pw_val" == *'='* ]]; then
        echo "ERROR: $pw_name contains a character (\" \\ # =) that breaks the INI/JSON config files it's embedded in. Use only alphanumerics and other punctuation."
        exit 1
    fi
done

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
       POOL_WALLET_ADDRESS POOL_DOMAIN EXPLORER_DOMAIN CERTBOT_EMAIL ADMIN_PASS

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

# defcoin-sync logs one line per RPC call (see patches/apply-patches.sh for
# why) -- routed to its own file instead of the journal, so it needs rotation.
sudo touch /var/log/defcoin-sync.log
sudo chown defcoin:defcoin /var/log/defcoin-sync.log
sudo cp "$SCRIPT_DIR/systemd/defcoin-sync.logrotate" /etc/logrotate.d/defcoin-sync

# defcoin-reconcile re-verifies blocksConfirmed against the live chain on a
# schedule (a "confirmed" round is never rechecked otherwise, so a
# deep-enough reorg can leave a phantom reward credited forever). oneshot +
# timer, not a long-running service.
sudo cp "$SCRIPT_DIR/systemd/defcoin-reconcile.service" /etc/systemd/system/
sudo cp "$SCRIPT_DIR/systemd/defcoin-reconcile.timer" /etc/systemd/system/
sudo mkdir -p /home/defcoin/scripts
sudo cp "$SCRIPT_DIR/scripts/reconcile-blocksConfirmed.py" /home/defcoin/scripts/
sudo chown defcoin:defcoin /home/defcoin/scripts/reconcile-blocksConfirmed.py
sudo touch /var/log/defcoin-reconcile.log
sudo chown defcoin:defcoin /var/log/defcoin-reconcile.log
sudo cp "$SCRIPT_DIR/systemd/defcoin-reconcile.logrotate" /etc/logrotate.d/defcoin-reconcile

sudo systemctl daemon-reload
sudo systemctl enable defcoind defcoin-pool defcoin-explorer defcoin-sync defcoin-reconcile.timer

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
echo "  sudo systemctl start defcoin-reconcile.timer"
echo ""
echo "Check logs:"
echo "  journalctl -u defcoind -f"
echo "  journalctl -u defcoin-pool -f"
echo "  journalctl -u defcoin-explorer -f"
echo "  tail -f /var/log/defcoin-reconcile.log"
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
