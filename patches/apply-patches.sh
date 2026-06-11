#!/usr/bin/env bash
# apply-patches.sh — copies patched source files over their npm-installed counterparts.
#
# These patches fix compatibility issues between the upstream packages and
# Defcoin-Core-Nu (v26, Bitcoin Core v26 fork):
#
#   merged-pooler/lib/pool.js
#     - Use getblockchaininfo instead of the removed getinfo RPC
#     - Synthesize getinfo response for code that still expects it
#     - Add segwit + mweb rules to getblocktemplate call
#
#   merged-pooler/lib/transactions.js
#     - Default coinbaseaux.flags to empty string when missing
#     - Fix txInPrevOutHash buffer construction
#
#   merged-pooler/lib/daemon.js
#     - Route getinfo calls through getblockchaininfo
#
#   unomp-pool/libs/paymentProcessor.js
#     - Use getaddressinfo instead of the removed validateaddress RPC
#
#   eiquidus/lib/database.js
#     - Fix Mongoose 9 breaking change: Model.find().countDocuments() removed;
#       use Model.countDocuments(filter) directly
#     - Guard against non-array return from get_last_txs_ajax
#
#   eiquidus/scripts/sync.js
#     - Skip MongoDB auth (unauthenticated local connection)
#     - Set NODE_OPTIONS for experimental-global-webcrypto on Node 18+

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POOL_DIR="${POOL_DIR:-/opt/defcoin-pool}"
EXPLORER_DIR="${EXPLORER_DIR:-/opt/defcoin-explorer}"

apply() {
    local src="$1" dst="$2"
    if [ ! -f "$dst" ]; then
        echo "  SKIP (target not found): $dst"
        return
    fi
    cp "$src" "$dst"
    echo "  PATCHED: $dst"
}

echo "=== Applying merged-pooler patches ==="
MP="$POOL_DIR/node_modules/merged-pooler/lib"
apply "$SCRIPT_DIR/merged-pooler/lib/pool.js"         "$MP/pool.js"
apply "$SCRIPT_DIR/merged-pooler/lib/transactions.js"  "$MP/transactions.js"
apply "$SCRIPT_DIR/merged-pooler/lib/daemon.js"        "$MP/daemon.js"

echo "=== Applying UNOMP pool patches ==="
apply "$SCRIPT_DIR/unomp-pool/libs/paymentProcessor.js" "$POOL_DIR/libs/paymentProcessor.js"

echo "=== Applying eIquidus patches ==="
apply "$SCRIPT_DIR/eiquidus/lib/database.js"    "$EXPLORER_DIR/lib/database.js"
apply "$SCRIPT_DIR/eiquidus/scripts/sync.js"    "$EXPLORER_DIR/scripts/sync.js"

echo ""
echo "All patches applied."
