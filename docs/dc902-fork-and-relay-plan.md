# Fork incident with dc902, and a direct-relay plan to prevent a repeat

**Status as of 2026-07-27:** fork with dc902's pool is unresolved (still growing). Direct block-relay push (`blocknotify`) is now **built, deployed, and confirmed working in both directions** between our own two nodes (main ↔ relay) — both manually tested and observed firing automatically on live blocks. Both nodes are also now running the same `v26.6.8-alpha` build, fully synced. Not yet extended to dc902 — pending them fixing their node first.

This doc covers: what happened, why it happened, what we've built in response, what it would take to extend that to dc902, and a suggested way forward.

## What happened

On 2026-07-26, dc902's node (`defcoin.dc903.org`, 50.116.19.40) diverged from our chain at approximately **block height 2,376,880** and has been mining an independent, isolated branch ever since.

**Evidence:**

1. **Frozen sync height, advancing headers.** Peer info for dc902's connections over an 8+ hour window:
   ```
   synced_blocks: 2376880   (unchanged for 8+ hours)
   synced_headers: climbing steadily (2377584 → 2378885+)
   inflight: []              (no active block download in progress)
   ```
   Their node knows headers exist past 2,376,880 but stopped downloading/validating the actual block bodies — stalled, not slow.

   Update 2026-07-27 01:31 UTC: their `synced_blocks` reading briefly flipped to `-1` (unknown) for the first time in 8+ hours — likely a reconnect on their end. The fork itself hadn't reconciled at that point (still growing, 2,005 blocks past the split).

2. **Confirmed different chains, not a sync lag.** At height 2,378,389, direct comparison:

   | | Block hash | Difficulty |
   |---|---|---|
   | dc902's chain | `542b1d9b32286c0a471fefdf5288e96eeaa4a4aaa1475cc9bd03ddc48a4e3723` | 5.7865 |
   | our chain | `85ec0b8422ccd790db646cf32833f9f00ff4d14995a0ef1af155ed85fac0fe74` | 6.056 |

   Same height, completely different blocks — a genuine fork, both sides retargeting difficulty independently since the split.

3. **Their own dashboard corroborates it:** `P2Pool Peers: 0 in / 0 out` (fully isolated at the sharechain layer); `Network Hashrate: 41.42 MH/s` vs. `Local/Global Pool Hashrate: 354–368 MH/s` (a ~9x mismatch — their node is reading a stale, pre-fork network view); `Current Difficulty: 1.4466` vs. our chain's actual ~6.06.

4. **Node/protocol gap.** Their node identifies as `DefcoinP2Pool:b8ba5c5-dirty`, protocol version **70002**. Every other active node we've observed negotiates at **70017** — a 15-version gap, and `-dirty` means uncommitted local modifications on top of a specific commit, not a clean release.

## Likely root cause

Around the fork time, our side absorbed a sudden ~70x hashrate increase (two ASICs coming online), which — combined with Defcoin's classic retarget (`nPowTargetSpacing=120s`, `nPowTargetTimespan=86400s`, adjusts once per 720 blocks) — produced a burst of very fast blocks before difficulty caught up. Their older/modified, isolated P2Pool build likely either had a bug handling that burst, or its isolation (0 P2Pool peers) meant it never validated our blocks fast enough and kept extending its own branch instead. Can't fully confirm without their logs.

## What would fix the fork itself (their side)

1. Check defcoind/P2Pool logs around the divergence point for errors/disconnects.
2. Add direct peers: `addnode=40.87.31.48`, `addnode=20.125.148.47`, restart, watch if `synced_blocks` starts climbing toward our tip (~2,378,970+ as of this writing).
3. If it doesn't self-resolve: full resync from a good peer. Everything confirmed on their branch since the split is unrecoverable — it never had a valid path back onto the network's chain.
4. Diff their `-dirty` build against upstream; consider rebasing onto a clean tag — both our nodes are now running `v26.6.8-alpha` from `github.com/defcoincore/Defcoin-Core-Nu`, fully synced and stable, might be a good base for them too.
5. Get onto protocol version 70017.

## Why this needs a structural fix, not just a one-time reconnect

A stuck/isolated node reconnecting fixes this instance, but the underlying risk is general: this network is small enough, and blocks fast enough, that any propagation gap between the handful of active nodes can turn into a real, non-reconciling fork rather than a normal one-block orphan. Bitcoin hit the same problem early on — small pools getting orphaned by slow propagation — and the historical fix was direct relay infrastructure between pools:

- **Bitcoin Relay Network** (Matt Corallo, 2015) — TCP relay nodes pools connected to for fast propagation.
- **FIBRE** (Corallo, 2016) — UDP + Forward Error Correction successor, sub-second global propagation. Declined ~2020 (one-person maintenance burden), recently revived by third parties.
- **Compact Blocks (BIP 152, 2016)** — the part that stuck: merged into Bitcoin Core itself, ~98% bandwidth reduction, why dedicated relay networks became less essential for typical nodes.

Real FIBRE (UDP/FEC, tied closely to mainline Bitcoin Core internals) isn't practical to port onto Defcoin-Core-Nu — too diverged a fork (different magic bytes, scrypt PoW, MWEB extensions as of v26.6.8-alpha). What follows is the practical, low-effort version of the same idea, built on what the codebase already has.

## What we built: direct block-relay push (`blocknotify`)

**How it works:**
1. `defcoind`'s `-blocknotify=<cmd>` fires the instant a node accepts a new best block.
2. A script (`scripts/blocknotify-push.sh` in this repo) fetches the raw block hex and pushes it directly to each configured peer's RPC via `submitblock` — skipping the normal INV → GETDATA announce/request round-trip.
3. The peer validates and accepts it (or returns `duplicate` if normal P2P relay already beat the push there — harmless, expected).

Doesn't touch consensus rules or pool software — just node config plus a small script layered on the existing RPC interface.

**Current status: confirmed working in both directions.** Deployed on both our nodes (main + relay), each already had its own existing `blocknotify` hook (the pool software's payout-round notifier on main; a debug logger on relay) — chained rather than replaced in both cases. Both directions tested manually (`submitblock` → `duplicate`, confirming auth + connectivity), and both have since fired automatically on real live blocks without any manual trigger — the push is genuinely live in production now, running alongside normal P2P gossip as a redundant fast path.

### Setup steps (per node)

1. **Deploy the script** to `~/scripts/blocknotify-push.sh`, `chmod 755`.
2. **Create a dedicated, narrowly-scoped RPC user** — not the pool's main `rpcuser`/`rpcpassword`. Generate with `rpcauth.py` (ships with Defcoin-Core-Nu at `source/share/rpcauth/rpcauth.py`), which stores only a salted hash in `defcoin.conf`:
   ```bash
   python3 ~/Defcoin-Core-Nu/source/share/rpcauth/rpcauth.py pushrelay <generated-password>
   # append the printed rpcauth= line to defcoin.conf
   ```
   The plaintext password only ever goes into the *other* node's `push-peers.conf` — never into `defcoin.conf`, never git-tracked, never pasted anywhere in the clear.
3. **Create `~/.defcoin/push-peers.conf`, chmod 600**, one line per peer: `<peer-host>:<peer-rpc-port>:pushrelay:<peer's-generated-password>`.
4. **Open RPC between the two nodes, scoped tightly.** `defcoin.conf`: `rpcallowip=<peer IP>` + `rpcbind=0.0.0.0:<port>` (RPC defaults to localhost-only — this deliberately opens it, so keep the allow-list to exactly the peer). Firewall/NSG: inbound rule on the RPC port, source restricted to the peer's exact IP.
5. **Wire up `blocknotify`.** If nothing else uses it: `blocknotify=/home/defcoin/scripts/blocknotify-push.sh %s`. **If something already uses it** (this bit us on our own main node — the pool software's own block-found hook was already wired up for UNOMP's payment-round processing) — don't overwrite it. `defcoind` only supports one `blocknotify=` line. Back up the existing wrapper, append a backgrounded call to the push script at the end of it instead.
6. **Restart `defcoind`** to pick up the config. A plain restart (no version change) is quick.
7. **Test before trusting it** — push an old, already-shared block hash manually and confirm you get `duplicate`, not a timeout/auth error.

### Why this needs both sides, not just one

This can't be set up unilaterally:
- Each side generates and hashes their **own** RPC credential; neither side can push to the other without the other minting a credential first.
- Each side needs the *other's* IP added to their own firewall/NSG allow-list.
- Each side needs the *other's* IP + port + credential in their own `push-peers.conf` — has to be exchanged, ideally not verbatim over a public/insecure channel.
- If a peer's node is unhealthy (like dc902's currently is), the push just times out into the log — doesn't help until their node can accept connections again.

**Onboarding checklist for a new pool operator:**
1. Exchange reachability details (IP, RPC port) — fine over any channel.
2. Each side independently generates a `pushrelay` rpcauth entry, shares only the resulting plaintext password over a reasonably private channel.
3. Each side adds the other's IP to `rpcallowip` + firewall/NSG, scoped exactly to that IP.
4. Each side adds the other's `host:port:pushrelay:<password>` line to their own `push-peers.conf`.
5. Both restart, test in both directions with an old shared block before relying on it live.

**Known limitations:** not real FIBRE (no UDP/FEC/multi-hop mesh, just a direct point-to-point push); only helps once both nodes are otherwise healthy and on the same chain — doesn't fix an already-isolated node (see: dc902 needs to resync before this does anything for them); one `blocknotify=` slot per node, remember to chain rather than overwrite if something else already uses it.

## Suggested way forward with dc902

1. **Share this doc (or the summary of it) with dc902's operator.** Collaborative framing — this happened to both of us, and the fix benefits both pools going forward.
2. **They diagnose and fix their node first** — the remediation steps above. Nothing else is useful until their node is actually caught up and matching our chain again.
3. **Once resynced and confirmed matching** (compare heights/hashes directly, same way we diagnosed the split), **extend the direct-relay setup to include them** as a third peer — walk through the onboarding checklist together, ideally live/on a call rather than async, since it's a credential exchange on both sides.
4. **Going forward:** coordinate before either side brings major new hashrate online (this is literally what triggered the original burst); consider basic monitoring that alerts if either side's synced height diverges from the other by more than a few blocks, so a future stall gets caught in minutes instead of hours.
5. **Longer-term, network-wide, not urgent:** the once-per-720-blocks retarget is slow to react to hashrate swings; a faster algorithm (DarkGravityWave, LWMA) would make the whole network more resilient to this class of event — but that's a consensus-level change needing coordinated buy-in across all operators, worth raising with dc902 as a future conversation, not part of the immediate fix.
