#!/usr/bin/env bash
# wait-for-defcoind.sh [timeout_seconds]
#
# Blocks until defcoind's RPC is actually responding, not just until the
# process has forked/written its PID file. Used as an ExecStartPre for
# defcoin-pool.service (and anything else that calls RPC on start) to close
# a startup race: `After=defcoind.service` only waits for defcoind's unit to
# report started, which for a Type=forking service happens well before RPC
# is ready (e.g. still "Loading block index..."). Pool software that fails
# its one init RPC call and gives up (rather than retrying) ends up "active"
# per systemd while its actual listener (e.g. stratum) never binds.

set -u

TIMEOUT="${1:-300}"
ELAPSED=0

until defcoin-cli getblockchaininfo >/dev/null 2>&1; do
    if [[ "$ELAPSED" -ge "$TIMEOUT" ]]; then
        echo "defcoind RPC not ready after ${TIMEOUT}s, giving up" >&2
        exit 1
    fi
    sleep 2
    ELAPSED=$((ELAPSED + 2))
done

echo "defcoind RPC ready after ${ELAPSED}s"
