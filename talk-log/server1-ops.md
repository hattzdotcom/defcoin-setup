# Server 1 — Live Config Tweaks (40.87.31.48 / defcoin.fun)

All changes applied manually post-install. Not reflected in the install scripts unless noted.

---

## defcoin.conf (`/home/defcoin/.defcoin/defcoin.conf`)

Added after initial install:

```
port=1337          # active network uses 1337, not the chainparams default of 17333
externalip=40.87.31.48  # node didn't know its external IP; localaddresses was []
txindex=1          # required by eIquidus explorer
```

**Write via Python only** — the RPC password contains `$C` which expands to empty string in bash heredocs.

### Peers removed (2026-06-13)

```
# removed — 367 blocks behind, caused batch-catchup dump events:
# addnode=135.148.43.188:10332

# removed preventively (same host):
# addnode=135.148.43.189:10332

# removed — dead/incompatible node (magic bytes fbc0b6db vs defc014e), banned 24h:
# addnode=128.100.103.169:17333
# addnode=128.100.103.169:1337
```

To restore, add back to defcoin.conf and run:
```bash
defcoin-cli setban '128.100.103.169' remove
```

---

## System — Swap (`/swapfile`)

No swap existed on this VM. Added 2 GB (2026-06-18):

```bash
fallocate -l 2G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
```

`/etc/fstab` entry:
```
/swapfile none swap sw 0 0
```

---

## MongoDB — WiredTiger Cache (`/etc/mongod.conf`)

Default cache (~1.4 GB) was spilling into swap. Capped at 1 GB (2026-06-19):

```yaml
storage:
  dbPath: /var/lib/mongodb
  wiredTiger:
    engineConfig:
      cacheSizeGB: 1
```

Restart required: `sudo systemctl restart mongod`

---

## Explorer — Node.js crypto fix (`/etc/systemd/system/defcoin-explorer.service`)

Node.js 16 needs `--experimental-global-webcrypto` or explorer workers crash with
`ReferenceError: crypto is not defined`. Added to the service unit:

```ini
Environment="NODE_OPTIONS=--experimental-global-webcrypto"
```

Applied to the web service (was already set on the sync service).

---

## Explorer — Network hashrate units

`nethash_units` was set to `"T"` (terahash). Network does ~3 MH/s so it displayed as 0.
Changed to `"M"` (megahash) in eIquidus `settings.json`.

---

## Pool — blocknotify.sh

UNOMP's CLI listener expects JSON; original script sent plain text, crashing the master
process with an uncaught `JSON.parse()` exception. Fixed format:

```bash
printf '{"command":"blocknotify","params":["defcoin","%s"],"options":{}}\n' "$1" \
  | nc -q 1 127.0.0.1 17323
```

---

## Pool — cliListener.js try-catch placement

The try-catch in `cliListener.js` wrapped the event *registration* call, not the handler
callback — so exceptions inside the handler were uncaught. Moved it inside the `data`
callback.

---

## defcoin-sync systemd service

Runs as a one-shot unit with `Restart=always` and `RestartSec=30`. Status showing
`activating` between runs is normal — not stuck.

---

## defcoind.service — crash loop fix (2026-06-29)

**Symptom:** After a VM reboot, `systemctl status defcoind` shows
`activating (auto-restart) (Result: exit-code)` in a tight loop. defcoind was
actually running and serving RPC, but systemd wasn't tracking it correctly.

**Root cause:** Stale or invalid `.defcoin/defcoind.pid` from the previous run.
`Type=forking` reads the PID file after the daemon forks. If the file has wrong
content, systemd can't track the child process, marks the service as failed, and
`Restart=on-failure` fires. Each restart attempt hits the lock held by the still-
running defcoind — counter goes to 90+ before systemd is manually stopped.

**Fix:** `ExecStartPre=-/bin/rm -f /home/defcoin/.defcoin/defcoind.pid` clears the
stale PID file before each start. `TimeoutStartSec=600` and `TimeoutStopSec=300`
give defcoind enough time to load the full block index and flush on shutdown.

See `systemd/defcoind.service` for the current unit.

---

## chainparams.cpp — added DNS seed (2026-06-29)

`seed.fuckyyourcoins.com` added to `vSeeds` in
`/home/defcoin/Defcoin-Core-Nu/source/src/chainparams.cpp` and DefcoinCoreNu
rebuilt on this node. Seed is live and returning peer IPs.

---

## Magic bytes — network migration (2026-06-29)

Two magic byte values exist on the network during migration:
- `fbc0b6db` — legacy (Litecoin-compatible), used by DefcoinCore:1.0.0 nodes
- `defc014e` — current, used by all DefcoinCoreNu:26.x nodes

**August 1, 2026 — hard enforcement cutoff.** DefcoinCoreNu will stop accepting
legacy magic after this date (per README and release notes in upstream repo).

This node stays in **compatibility mode** (default: `acceptlegacymagic=true`).
The pool needs to propagate blocks to all miners including old-magic nodes.
Setting `acceptlegacymagic=0` on this node caused an OOM-triggered VM crash
on 2026-06-29 — do not set this here until the network has mostly migrated.

The relay node (20.125.148.47) runs `acceptlegacymagic=0` to build the
clean-magic peer set for post-cutoff operation.
