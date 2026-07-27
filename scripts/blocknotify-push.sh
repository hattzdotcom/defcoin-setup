#!/usr/bin/env bash
# blocknotify-push.sh <blockhash>
#
# Direct block-relay push: on every new best block, immediately pushes the raw
# block to each configured peer's RPC via submitblock, bypassing the normal
# INV/GETDATA announce cycle. See ../docs/blocknotify-relay.md for why this
# exists and how to set it up.
#
# Wired up via defcoin.conf:
#   blocknotify=/home/defcoin/scripts/blocknotify-push.sh %s
#
# If defcoind already has a blocknotify hook (e.g. the pool software's own),
# do NOT overwrite it — append a call to this script to the end of the
# existing wrapper instead, run in the background so it doesn't block the
# pool's own notification path.
#
# Peers are listed one per line in push-peers.conf as: host:port:user:pass
# That file must be chmod 600 and must never be committed to git.

set -uo pipefail

BLOCKHASH="${1:?usage: blocknotify-push.sh <blockhash>}"
CONF_FILE="$HOME/.defcoin/push-peers.conf"
LOGFILE="$HOME/.defcoin/blocknotify-push.log"
TIMEOUT_SECS=5

log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "$LOGFILE"; }

if [[ ! -f "$CONF_FILE" ]]; then
    log "ERROR no peer conf at $CONF_FILE"
    exit 0
fi

RAWBLOCK=$(defcoin-cli getblock "$BLOCKHASH" 0 2>>"$LOGFILE")
if [[ -z "$RAWBLOCK" ]]; then
    log "ERROR failed to fetch raw hex for $BLOCKHASH"
    exit 0
fi

while IFS=: read -r HOST PORT USER PASS; do
    [[ -z "${HOST:-}" || "$HOST" == \#* ]] && continue
    (
        RESULT=$(timeout "$TIMEOUT_SECS" defcoin-cli -rpcconnect="$HOST" -rpcport="$PORT" \
                 -rpcuser="$USER" -rpcpassword="$PASS" submitblock "$RAWBLOCK" 2>&1)
        RC=$?
        if [[ $RC -ne 0 ]]; then
            log "FAIL push $BLOCKHASH -> $HOST:$PORT (rc=$RC): $RESULT"
        elif [[ -z "$RESULT" ]]; then
            log "OK push $BLOCKHASH -> $HOST:$PORT (accepted)"
        else
            # "duplicate" / "inconclusive" are expected/benign, just log for visibility
            log "INFO push $BLOCKHASH -> $HOST:$PORT: $RESULT"
        fi
    ) &
done < "$CONF_FILE"

wait
