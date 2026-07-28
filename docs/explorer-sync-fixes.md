# Explorer sync fixes (2026-07-27)

Two independent bugs were found and fixed after a VM resize/restart cycle left the explorer showing stale data (frozen at a specific block, hours out of date) despite `defcoind`, the pool, and MongoDB all reporting healthy.

## Bug 1: Node 16 / mongodb driver crypto incompatibility

**Symptom:** `defcoin-sync` (and potentially `defcoin-explorer`) throws `ReferenceError: crypto is not defined` inside the `mongodb` driver's session/cursor cleanup code, immediately on any database query.

**Cause:** Node 18+ exposes `crypto` as a true global; Node 17.6+ can opt in via `--experimental-global-webcrypto`. Node 16 (what these servers run) has neither — the flag doesn't exist on 16 and is silently ignored rather than erroring, so `NODE_OPTIONS=--experimental-global-webcrypto` alone (the existing fix for this in `apply-patches.sh`) does nothing on this Node version. A newer `mongodb` driver package assumes `globalThis.crypto` exists regardless.

Critically, `sync.js`'s `db.check_stats` swallows this exception and misreports it as "database structures don't exist," rather than surfacing the real error — the visible symptom was `Run 'npm start' to create database structures before running this script.`, which is misleading.

**Fix:** `patches/eiquidus/scripts/webcrypto-shim.js` — a one-line polyfill (`globalThis.crypto = require('crypto').webcrypto`) loaded via `NODE_OPTIONS=--require` in both `defcoin-sync.service` and `defcoin-explorer.service`. Node 16's built-in `crypto` module already exposes `.webcrypto`; it just isn't promoted to a global automatically.

## Bug 2: `rpc_queue` permanently jams after the first RPC call

**Symptom:** past bug 1, `sync.js` starts, connects to MongoDB fine, but never makes visible progress — no errors, no timeouts, an idle event loop (confirmed via a Node `--report-on-signal` diagnostic report showing zero active handles beyond the MongoDB connection pool).

**Cause:** `lib/node.js`'s `rpc_queue` (an `async.queue` with concurrency 1, from `lib/explorer.js`) calls `client.cmd()` for each queued RPC command. Empirically, the success callback passed down to the underlying `jsonrpc.js` request never fires unless a synchronous `console.error`/`console.log` call runs as its first statement. Without one, the first RPC call's callback is silently lost, and since queue concurrency is 1, every subsequent `rpcCommand()` call queues behind it forever.

This was bisected carefully — ruled out as the cause: a pure no-op (`void 0`), a non-console synchronous syscall (`fs.fstatSync`, `fs.writeSync` to an open fd), `process.stderr.write()` directly, and `setImmediate()` deferral. Only an actual `console.error`/`console.log` call fixes it, and it's needed on (nearly) every invocation — throttling to every 20th call was insufficient. The exact internal Node/V8 mechanism was not identified; this is a working, verified fix, not a full root-cause explanation.

**Fix:** `patches/eiquidus/lib/node.js` — adds `console.error('.')` as the first statement in the RPC success callback. Kept to a single character to bound output volume, since this can run millions of times during a full resync.

**Side effect this required:** because of the log volume, `defcoin-sync.service`'s output is now routed to `/var/log/defcoin-sync.log` (with `systemd/defcoin-sync.logrotate`) instead of the systemd journal, to avoid bloating the shared system journal.

## Bug 3 (contributing factor, not a code bug): `sync.batch_size` vs. `Restart=always`

**Symptom:** even after bugs 1 and 2 were fixed, `sync.js` would run, process blocks successfully, print "Block sync complete," and exit — but the `blocks`-derived collections never gained any new documents.

**Cause:** eIquidus batches writes and only flushes once `sync.batch_size` (default 5000) blocks have accumulated *within a single process run*. `defcoin-sync.service` uses `Restart=always`/`RestartSec=30` — a one-shot-per-cycle pattern that's normal and by design (see main README). Once caught up, each cycle only has a handful of new blocks to process (blocks land every ~2 minutes) — nowhere near 5000 — so the in-memory batch is discarded on every exit before it ever flushes. Under steady-state operation with the default batch size, indexed data would never be written at all.

This surfaced during recovery specifically because the sync bookmark (`coinstats.last`, checked via `mongosh defcoin --eval 'db.getCollection("coinstats").findOne()'`) had drifted far behind the actual chain tip — over a million blocks — so the first realization of this problem looked like "reprocessing does nothing," when actually every run was correctly processing its (tiny) chunk of new blocks and then discarding it unflushed.

**Fix:** `sync.batch_size` set to `1` in `settings.json` (see `03-setup-explorer.sh`). A large batch size only makes sense for a single long-running initial sync; it's actively harmful for a restart-per-cycle steady-state service like this one.

## Related, unrelated-looking finding: there is no `Block` model

While debugging bug 3, it became clear this version of eIquidus has no `models/block.js` and no dedicated `blocks` MongoDB collection at all — block/transaction listings are derived entirely from the `txes` collection (grouped by `blockindex`/`blockhash`). An empty or missing `blocks` collection is not itself a sign of a problem; don't chase it as one. The actual site-visible symptom (a frozen "latest transactions" list) is driven by `txes`, and was confirmed fixed by checking `/ext/getlasttxs/0/0/N/internal` directly against the real chain tip, not by looking for `blocks` documents.
