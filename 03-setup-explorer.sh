#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export HOME="${HOME:-$(getent passwd "$(id -un)" | cut -d: -f6)}"
export USER="${USER:-$(id -un)}"
set +u
[ -f "$SCRIPT_DIR/vars.sh" ] && . "$SCRIPT_DIR/vars.sh"
set -u

echo "=== Phase 4: Setting up eIquidus block explorer ==="

# ── MongoDB 6.0 ───────────────────────────────────────────────────────────────
if ! command -v mongod &>/dev/null; then
    wget -qO - https://www.mongodb.org/static/pgp/server-6.0.asc \
        | sudo gpg --dearmor -o /usr/share/keyrings/mongodb-server-6.0.gpg

    echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-6.0.gpg ] \
https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/6.0 multiverse" \
        | sudo tee /etc/apt/sources.list.d/mongodb-org-6.0.list

    sudo apt-get update -qq
    sudo apt-get install -y mongodb-org
fi

sudo systemctl enable mongod
sudo systemctl start mongod
echo "MongoDB $(mongod --version | head -1)"

# ── eIquidus ─────────────────────────────────────────────────────────────────
sudo mkdir -p "$EXPLORER_DIR"
sudo chown "$USER":"$USER" "$EXPLORER_DIR"

if [ ! -d "$EXPLORER_DIR/.git" ]; then
    git clone https://github.com/team-exor/eiquidus "$EXPLORER_DIR"
fi

git config --global --add safe.directory "$EXPLORER_DIR" 2>/dev/null || true
cd "$EXPLORER_DIR"
git pull --ff-only
npm install --production

# ── settings.json ────────────────────────────────────────────────────────────
# eIquidus ships with settings.json.template; we write our own directly.
cat > "$EXPLORER_DIR/settings.json" <<EOF
{
  "title": "Defcoin Explorer",
  "address": "0.0.0.0",
  "port": 3001,
  "coin": "Defcoin",
  "symbol": "DFC",
  "logo": "/images/logo.png",
  "favicon": "public/favicon.ico",
  "theme": "Cerulean",
  "dbsettings": {
    "database": "defcoin",
    "address": "127.0.0.1",
    "port": 27017
  },
  "wallet": {
    "host": "127.0.0.1",
    "port": 17332,
    "username": "${RPC_USER}",
    "password": "${RPC_PASS}"
  },
  "update_timeout": 10,
  "check_timeout": 250,
  "block_parallel_tasks": 1,
  "use_rpc": true,
  "explorer_url": "https://${EXPLORER_DOMAIN}",
  "display": {
    "api": true,
    "markets": false,
    "richlist": true,
    "twitter": false,
    "search": true,
    "claims": false,
    "masternodes": false,
    "movement": true
  },
  "index": {
    "show_hashrate": true,
    "show_difficulty": true,
    "show_masternodes": false,
    "difficulty": "POW",
    "last_txs": 100,
    "txs_per_page": 10
  },
  "api": {
    "blockindex": true,
    "blockhash": true,
    "blockcount": true,
    "marketcap": false,
    "sendtx": true,
    "circulation": true,
    "getnetworkhashps": true
  },
  "richlist": {
    "distribution": true,
    "received": true,
    "balance": true
  },
  "movement": {
    "min_amount": 100,
    "low_flag": 1000,
    "high_flag": 10000
  },
  "shared_pages": {
    "page_header": {
      "show_logo": true,
      "search": {
        "enabled": true
      }
    },
    "page_footer": {
      "social_links": []
    }
  },
  "genesis_tx": "",
  "genesis_block": "",
  "heavy": false,
  "txcount": 100,
  "show_sent_received": true,
  "supply": "COINBASE",
  "nethash_units": "T"
}
EOF

# ── Apply compatibility patches ───────────────────────────────────────────────
echo "=== Applying eIquidus patches ==="
EXPLORER_DIR="$EXPLORER_DIR" bash "$SCRIPT_DIR/patches/apply-patches.sh"

echo ""
echo "=== Explorer setup complete ==="
echo "Initial sync: cd $EXPLORER_DIR && node scripts/sync.js index update"
echo "Then start:   node bin/cluster"
echo "Runs on port 3001"
