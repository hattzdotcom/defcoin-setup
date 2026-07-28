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
#
#   eiquidus/scripts/webcrypto-shim.js  (new file, not an overlay)
#     - Node 16 doesn't expose crypto as a global (that's Node 18+, or
#       --experimental-global-webcrypto from Node 17.6+ -- a flag Node 16
#       silently ignores since it doesn't exist there). A newer mongodb
#       driver version assumes globalThis.crypto is available and throws
#       "ReferenceError: crypto is not defined" in session/cursor cleanup
#       otherwise. Promotes Node 16's crypto.webcrypto to a global; loaded
#       via NODE_OPTIONS=--require in the systemd units.
#
#   eiquidus/lib/node.js
#     - Fixes a silent hang: sync.js's rpc_queue (concurrency 1) never
#       actually invokes its success callback after the first RPC call
#       unless something synchronous (specifically a console.error/log
#       call -- see comment in the file) runs as its first statement.
#       Without it, every later RPC call queues behind the jammed first
#       one forever, with no error, no timeout, and an idle event loop.
#       See the file's own comment for what was ruled out.

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

install_new() {
    local src="$1" dst="$2"
    cp "$src" "$dst"
    echo "  INSTALLED: $dst"
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
apply "$SCRIPT_DIR/eiquidus/lib/node.js"        "$EXPLORER_DIR/lib/node.js"
apply "$SCRIPT_DIR/eiquidus/scripts/sync.js"    "$EXPLORER_DIR/scripts/sync.js"
install_new "$SCRIPT_DIR/eiquidus/scripts/webcrypto-shim.js" "$EXPLORER_DIR/scripts/webcrypto-shim.js"

echo ""
echo "All patches applied."
