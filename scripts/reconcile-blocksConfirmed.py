#!/usr/bin/env python3
"""
reconcile-blocksConfirmed.py

Re-validates every entry in the pool's Redis `blocksConfirmed` set against
the live chain. UNOMP classifies a block as confirmed once, based on the
wallet's gettransaction category at that moment, and never rechecks it --
if a deeper-than-usual reorg happens afterward, an already-"confirmed"
entry can silently become phantom: its reward credit sits in
defcoin:balances forever, but the block isn't actually on the chain
anymore.

Run on a schedule (see systemd/defcoin-reconcile.timer) as an ongoing
safety net -- this is the thing that actually closes the gap between
Redis bookkeeping and the live chain, instead of relying on someone
noticing balances look wrong.

Reads RPC credentials from ~/.defcoin/defcoin.conf at runtime -- never
hardcode them in this file.

Usage:
  python3 reconcile-blocksConfirmed.py              # dry run, report only
  python3 reconcile-blocksConfirmed.py --apply       # also correct redis:
                                                      #   - reverse the balance credit
                                                      #   - move the entry to blocksOrphaned
"""
import subprocess, sys, json, base64, urllib.request, os
from collections import defaultdict

CONF_PATH = os.path.expanduser("~/.defcoin/defcoin.conf")
COIN = "defcoin"


def load_rpc_creds():
    user = password = None
    port = "17332"
    with open(CONF_PATH) as f:
        for line in f:
            line = line.strip()
            if line.startswith("rpcuser="):
                user = line.split("=", 1)[1]
            elif line.startswith("rpcpassword="):
                password = line.split("=", 1)[1]
            elif line.startswith("rpcport="):
                port = line.split("=", 1)[1]
    if not user or not password:
        sys.exit("Could not find rpcuser/rpcpassword in " + CONF_PATH)
    return user, password, port


def rpc_call(user, password, port, method, params=None):
    payload = json.dumps({"id": "reconcile", "method": method, "params": params or []}).encode()
    req = urllib.request.Request(f"http://127.0.0.1:{port}/", data=payload, method="POST")
    auth = base64.b64encode(f"{user}:{password}".encode()).decode()
    req.add_header("Authorization", f"Basic {auth}")
    req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=10) as resp:
        result = json.loads(resp.read())
    if result.get("error"):
        raise RuntimeError(result["error"])
    return result["result"]


def redis_smembers(key):
    out = subprocess.check_output(["redis-cli", "SMEMBERS", key], text=True)
    return [l for l in out.splitlines() if l]


def redis_hincrbyfloat(key, field, amount):
    subprocess.check_call(["redis-cli", "HINCRBYFLOAT", key, field, str(amount)])


def redis_smove(src, dst, member):
    subprocess.check_call(["redis-cli", "SMOVE", src, dst, member])


def main():
    apply_changes = "--apply" in sys.argv
    user, password, port = load_rpc_creds()

    entries = redis_smembers(f"{COIN}:blocksConfirmed")
    print(f"Checking {len(entries)} entries in {COIN}:blocksConfirmed against live chain...")

    height_hash_cache = {}
    mismatches = []
    matches = 0
    parse_errors = 0

    for i, raw in enumerate(entries):
        parts = raw.split(":")
        if len(parts) < 6:
            parse_errors += 1
            continue
        block_hash, tx_hash, height, worker, ts, reward_sat = parts[0], parts[1], parts[2], parts[3], parts[4], parts[5]

        if height not in height_hash_cache:
            try:
                height_hash_cache[height] = rpc_call(user, password, port, "getblockhash", [int(height)])
            except Exception:
                height_hash_cache[height] = None  # height doesn't exist on current chain at all

        real_hash = height_hash_cache[height]

        if real_hash == block_hash:
            matches += 1
        else:
            reward_dfc = int(reward_sat) / 1e8
            mismatches.append({
                "raw": raw, "height": height, "worker": worker,
                "recorded_hash": block_hash, "real_hash": real_hash,
                "reward_dfc": reward_dfc
            })

        if (i + 1) % 200 == 0:
            print(f"  ...{i+1}/{len(entries)} checked")

    print()
    print("=== Results ===")
    print(f"Checked:        {len(entries)}")
    print(f"Parse errors:   {parse_errors}")
    print(f"Genuinely confirmed (hash matches live chain): {matches}")
    print(f"Phantom (hash mismatch -- orphaned, never reclassified): {len(mismatches)}")
    print()

    if mismatches:
        per_worker = defaultdict(float)
        for m in mismatches:
            per_worker[m["worker"]] += m["reward_dfc"]

        print("Phantom reward by worker (this much needs reversing from defcoin:balances):")
        total = 0.0
        for worker, amount in sorted(per_worker.items(), key=lambda x: -x[1]):
            print(f"  {worker:60s} {amount:>15.8f} DFC")
            total += amount
        print(f"  {'TOTAL':60s} {total:>15.8f} DFC")
        print()

        print("Sample mismatches (first 10):")
        for m in mismatches[:10]:
            real = m['real_hash'] or 'HEIGHT NOT FOUND'
            print(f"  height={m['height']} worker={m['worker']} reward={m['reward_dfc']} "
                  f"recorded={m['recorded_hash'][:16]}... real={real[:16]}...")

    if apply_changes:
        if not mismatches:
            print("Nothing to apply.")
            return
        print()
        print(f"=== ALERT: applying corrections to Redis ({len(mismatches)} entries) ===")
        for m in mismatches:
            redis_hincrbyfloat(f"{COIN}:balances", m["worker"], -m["reward_dfc"])
            redis_smove(f"{COIN}:blocksConfirmed", f"{COIN}:blocksOrphaned", m["raw"])
            print(f"  corrected: {m['worker']} -{m['reward_dfc']} DFC, moved to blocksOrphaned")
        print("Done.")
    elif mismatches:
        print()
        print("Dry run only -- no changes made. Re-run with --apply to correct Redis.")


if __name__ == "__main__":
    main()
