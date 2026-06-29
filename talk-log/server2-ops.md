# Server 2 — Live Config (20.125.148.47 / fuckyyourcoins.com)

Relay-only node. No pool, no explorer. Runs defcoind + defcoin-seeder.
Spun up 2026-06-12, relay seeder added 2026-06-29.

Azure: Standard_B2s, resource group `fuckyourcoins-rg`, VM name `fuckyourcoins-node`.
Domain: fuckyyourcoins.com (two Y's — intentional). SSH: `ssh -i ~/.ssh/defcoin_azure defcoin@20.125.148.47`.

---

## defcoin.conf (`/home/defcoin/.defcoin/defcoin.conf`)

```
port=1337
externalip=20.125.148.47
acceptlegacymagic=0
```

`acceptlegacymagic=0` — relay only peers with `defc014e` nodes, building the
clean-magic peer set for post-August-1-2026 network operation.

Write via Python (same `$C` password expansion issue as node 1).

---

## defcoind.service

See `systemd/defcoind-relay.service`. Key differences from main node:
- No `Group=defcoin`
- Uses `-conf=` flag explicitly (no `-pid=` flag; defcoind writes pid file by default)
- Same `ExecStartPre` stale-PID-file fix and extended timeouts

Relay node's defcoind was in a crash loop at restart counter **944** when the fix
was applied on 2026-06-29. Root cause identical to main node: stale PID file
causing `Type=forking` to mistrack the daemon.

---

## DNS Seed — seed.fuckyyourcoins.com (live 2026-06-29)

### Setup
Binary built from sipa/bitcoin-seeder at `/home/defcoin/defcoin-seeder/dnsseed`.

Patches applied before build:
1. User agent changed from `/bitcoin-seeder:0.01/` to `/DefcoinCore-seeder:0.01/`
   — DefcoinCoreNu rejects inbound connections with non-Defcoin-prefixed user agents.
2. `GetTimeout()` returns 30s for non-Tor connections.

### DNS
fuckyyourcoins.com moved to Cloudflare (free tier). Hover doesn't support NS
records for subdomains without full NS delegation.

Cloudflare records:
- `seed.fuckyyourcoins.com` NS → `ns1seed.fuckyyourcoins.com`
- `ns1seed.fuckyyourcoins.com` A → `20.125.148.47`

Azure NSG: DNS-UDP (priority 130) and DNS-TCP (priority 131) open on
`fuckyourcoins-nodeNSG`.

Port 53 conflict resolved: `DNSStubListener=no` in `/etc/systemd/resolved.conf`,
then `systemctl restart systemd-resolved`.

### systemd unit
`/etc/systemd/system/defcoin-seeder.service` — `AmbientCapabilities=CAP_NET_BIND_SERVICE`
grants port 53 binding without root; survives binary rebuilds (unlike `setcap`).

Key flags: `--magic defc014e --p2port 1337 -s 50.116.19.40 -s 40.87.31.48`
Pass seed IPs WITHOUT port suffix — port comes from `--p2port` only.

### Bugs fixed during setup
1. Seeds with `:port` suffix (e.g. `50.116.19.40:1337`) caused only 1 node to
   appear in DB due to LookupHost parsing. Use plain IPs.
2. User agent `/bitcoin-seeder:0.01/` silently rejected by DefcoinCoreNu inbound
   filter — patched to `/DefcoinCore-seeder:0.01/`.
3. `setcap` on binary wiped by each `make` rebuild (new inode). Replaced with
   `AmbientCapabilities` in systemd.

### Verify
```bash
nslookup seed.fuckyyourcoins.com 8.8.8.8
```
Should return live peer IPs.

---

## Azure PTR (reverse DNS) quirk

Azure won't set PTR for `ns1seed.fuckyyourcoins.com.` — it validates that the
FQDN resolves back through its own subscription records. Since `ns1seed` is a
glue record pointing to Cloudflare's NS, Azure can't validate it.
Relay PTR is just `fuckyyourcoins.com.` (the apex domain).

---

## nginx

`sites-enabled` file is named `fuckyourcoins` (one Y) — cosmetic/harmless.
Site redirects to defcoin.fun.
