# defcoin-setup

> **Work in progress** — these scripts are what we actually ran to bring [pool.defcoin.fun](https://pool.defcoin.fun) and [explorer.defcoin.fun](https://explorer.defcoin.fun) back online. They are not polished or generalized yet. Expect rough edges.

Automated setup scripts for running a [Defcoin (DFC)](https://github.com/defcoincore/Defcoin-Core-Nu) full node, UNOMP mining pool, and eIquidus block explorer on a single Ubuntu 22.04 VM.

## What this runs

| Service | Port | Notes |
|---|---|---|
| defcoind | 17332 (RPC), 17333 (P2P) | Defcoin-Core-Nu v26.3.1 |
| UNOMP mining pool | 3333 (stratum), 8080 (web) | scrypt, varDiff |
| eIquidus explorer | 3001 (web) | ~50 hour initial block sync |
| nginx | 80/443 | Reverse proxy + Let's Encrypt SSL |

## Requirements

- Ubuntu 22.04 LTS VM (tested on Azure Standard_B2s — 2 vCPU, 4 GB RAM)
- 64 GB disk (chain grows ~10 GB/year)
- Public IP and DNS A records for your pool/explorer domains
- Ports 17333 and 3333 open inbound in your firewall/NSG

## Quick start

```bash
git clone https://github.com/hattzdotcom/defcoin-setup
cd defcoin-setup

# 1. Fill in your values
cp vars.sh vars.sh.local   # optional — or just edit vars.sh directly
nano vars.sh               # set RPC_PASS, POOL_WALLET_ADDRESS, domains, email

# 2. Run
bash install.sh
```

Skip individual phases with flags:
```
bash install.sh --skip-node --skip-pool --skip-explorer --skip-nginx
```

## What the scripts do

| Script | Phase |
|---|---|
| `01-build-node.sh` | Builds Berkeley DB 4.8, then builds `defcoind` from source |
| `02-setup-pool.sh` | Installs Node 16, Redis, UNOMP; applies patches (see below) |
| `03-setup-explorer.sh` | Installs MongoDB 6, eIquidus; applies patches |
| `04-setup-nginx.sh` | Configures nginx vhosts, issues Let's Encrypt certs |

After install, systemd services are enabled. Start them in order:
```bash
sudo systemctl start defcoind
# wait for sync: defcoin-cli getblockchaininfo | grep blocks
sudo systemctl start defcoin-pool defcoin-explorer defcoin-sync
```

## Patches

`patches/apply-patches.sh` copies fixed source files over their npm-installed counterparts. These are the compatibility issues we hit:

### merged-pooler (UNOMP stratum backend)

**pool.js** — Defcoin-Core-Nu v26 removed the `getinfo` RPC (inherited from Bitcoin Core v26). Patch synthesizes a `getinfo` response from `getblockchaininfo` and adds `segwit` + `mweb` rules to `getblocktemplate` calls.

**daemon.js** — Routes any remaining `getinfo` calls through `getblockchaininfo`.

**transactions.js** — Defaults `coinbaseaux.flags` to an empty string when the daemon doesn't return it, and fixes `txInPrevOutHash` buffer construction.

### bignum (embedded in UNOMP)

The `bignum` npm package uses a pre-NAN native V8 API that won't compile on Node 12+. `02-setup-pool.sh` replaces it with a pure-JS BigInt implementation.

**Critical:** the replacement must honor the `{endian: 'little'}` option in `fromBuffer`. Without this, scrypt share hashes are interpreted as big-endian numbers — making the computed share difficulty near-zero — and every submitted share is rejected as "low difficulty".

### UNOMP paymentProcessor.js

`validateaddress` was removed in Bitcoin Core v24. Patch uses `getaddressinfo` instead.

### eIquidus

**database.js** — Mongoose 9 removed `Query.prototype.countDocuments()`. Three call sites used `Model.find(filter).countDocuments()` which is now invalid; patched to `Model.countDocuments(filter)`. Also added an `Array.isArray` guard to prevent a crash when the query returns an error object instead of an array.

**sync.js** — Skips MongoDB authentication (local unauthenticated connection) and sets `NODE_OPTIONS=--experimental-global-webcrypto` for Node 18+ compatibility.

## Mining

Connect any scrypt miner to `stratum+tcp://pool.defcoin.fun:3333`:

```
# cpuminer
minerd -a scrypt -o stratum+tcp://pool.defcoin.fun:3333 -u YOUR_DFC_ADDRESS -p x

# cgminer
cgminer -a scrypt -o stratum+tcp://pool.defcoin.fun:3333 -u YOUR_DFC_ADDRESS -p x

# sgminer
sgminer -k scrypt -o stratum+tcp://pool.defcoin.fun:3333 -u YOUR_DFC_ADDRESS -p x
```

VarDiff adjusts your difficulty automatically (min 0.5, max 512, targeting ~15 sec/share). Minimum payout: 0.5 DFC.

## Known issues / TODO

- [ ] Explorer takes ~50 hours to do its initial block sync (~2.3M blocks as of June 2026)
- [ ] Pool web UI is UNOMP's default Bootstrap template with minor branding changes
- [ ] No monitoring/alerting setup
- [ ] Payout logic not heavily tested (only one miner so far)
- [ ] Bootstrap archive can speed up initial node sync: [Defcoin-bootstrap-mainnet-2332283.zip](https://github.com/defcoincore/Defcoin-Core-Nu/releases/download/v26.3.1/Defcoin-bootstrap-mainnet-2332283.zip)

## Defcoin network info

- Algorithm: scrypt (N=1024, r=1, p=1)
- Block time: 2 minutes
- Total supply: ~84 million DFC
- Address prefix: D (byte 30)
- P2P port: 17333
- RPC port: 17332
