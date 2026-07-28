#!/usr/bin/env python3
"""
update-seed-bootstrap-dns.py

Keeps bootstrap.fuckyyourcoins.com's A records in sync with the peer
addresses our own main + relay Defcoin nodes currently know about
(`getnodeaddresses`). The DNS seeder (defcoin-seeder.service) re-resolves
its `-s` seed hostnames every 30 minutes on its own -- pointing it at this
hostname instead of a hardcoded IP list means new peers our nodes learn
about get picked up automatically, without ever touching the seeder again.

Why not crawl the network ourselves for this: the seeder's own crawler
already tries and mostly fails to discover new peers via GETADDR, since
modern Bitcoin-Core-derived nodes privacy-harden addr relay to short-lived
crawler-style connections. Our own long-lived, already-peered nodes don't
have that problem -- they organically accumulate real addr-relay gossip
over time, so this reuses that instead of re-solving the same problem.

Reads the Cloudflare API token from ~/.cf_api_token.env (CF_API_TOKEN=...)
at runtime -- never hardcode it in this file.

Usage:
  python3 update-seed-bootstrap-dns.py              # dry run, report only
  python3 update-seed-bootstrap-dns.py --apply       # actually update DNS
"""
import subprocess, sys, json, os, urllib.request

TOKEN_PATH = os.path.expanduser("~/.cf_api_token.env")
ZONE_NAME = "fuckyyourcoins.com"
RECORD_NAME = "bootstrap.fuckyyourcoins.com"
MAIN_NODE_SSH_KEY = os.path.expanduser("~/.ssh/main_node_readonly")
MAIN_NODE_HOST = "40.87.31.48"
MAIN_NODE_USER = "defcoin"


def load_cf_token():
    with open(TOKEN_PATH) as f:
        for line in f:
            line = line.strip()
            if line.startswith("CF_API_TOKEN="):
                return line.split("=", 1)[1]
    sys.exit("Could not find CF_API_TOKEN in " + TOKEN_PATH)


def cf_api(token, method, path, body=None):
    url = f"https://api.cloudflare.com/client/v4{path}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=15) as resp:
        result = json.loads(resp.read())
    if not result.get("success"):
        raise RuntimeError(result.get("errors"))
    return result["result"]


def get_local_addresses():
    out = subprocess.check_output(["defcoin-cli", "getnodeaddresses", "0"], text=True)
    return json.loads(out)


def get_main_node_addresses():
    out = subprocess.check_output(
        ["ssh", "-i", MAIN_NODE_SSH_KEY, "-o", "BatchMode=yes",
         f"{MAIN_NODE_USER}@{MAIN_NODE_HOST}", "ignored"],
        text=True
    )
    return json.loads(out)


def main():
    apply_changes = "--apply" in sys.argv

    print("Fetching addresses from relay node (local)...")
    local_addrs = get_local_addresses()
    print(f"  {len(local_addrs)} known")

    print("Fetching addresses from main node (via restricted SSH key)...")
    try:
        main_addrs = get_main_node_addresses()
        print(f"  {len(main_addrs)} known")
    except Exception as e:
        print(f"  FAILED: {e} -- continuing with relay-only addresses")
        main_addrs = []

    all_ipv4 = set()
    for a in local_addrs + main_addrs:
        addr = a.get("address", "")
        if ":" not in addr:  # IPv4 only -- keep parity with the seeder's existing -s list
            all_ipv4.add(addr)

    print(f"\nMerged unique IPv4 addresses: {len(all_ipv4)}")
    for ip in sorted(all_ipv4):
        print(" ", ip)

    token = load_cf_token()

    print(f"\nLooking up zone id for {ZONE_NAME}...")
    zones = cf_api(token, "GET", f"/zones?name={ZONE_NAME}")
    if not zones:
        sys.exit(f"Zone {ZONE_NAME} not found")
    zone_id = zones[0]["id"]

    print(f"Fetching current A records for {RECORD_NAME}...")
    existing = cf_api(token, "GET", f"/zones/{zone_id}/dns_records?type=A&name={RECORD_NAME}")
    existing_ips = {r["content"]: r["id"] for r in existing}
    print(f"  {len(existing_ips)} currently published")

    to_add = all_ipv4 - set(existing_ips.keys())
    to_remove = set(existing_ips.keys()) - all_ipv4

    print(f"\nTo add:    {sorted(to_add)}")
    print(f"To remove: {sorted(to_remove)}")

    if not apply_changes:
        print("\nDry run only -- no changes made. Re-run with --apply to update DNS.")
        return

    for ip in to_add:
        cf_api(token, "POST", f"/zones/{zone_id}/dns_records", {
            "type": "A", "name": RECORD_NAME, "content": ip,
            "ttl": 300, "proxied": False
        })
        print(f"  added {ip}")

    for ip in to_remove:
        cf_api(token, "DELETE", f"/zones/{zone_id}/dns_records/{existing_ips[ip]}")
        print(f"  removed {ip}")

    print("Done.")


if __name__ == "__main__":
    main()
