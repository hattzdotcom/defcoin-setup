#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export HOME="${HOME:-$(getent passwd "$(id -un)" | cut -d: -f6)}"
export USER="${USER:-$(id -un)}"
set +u
# shellcheck source=vars.sh
[ -f "$SCRIPT_DIR/vars.sh" ] && . "$SCRIPT_DIR/vars.sh"
set -u

echo "=== Phase 3: Setting up UNOMP mining pool ==="

# ── Redis ─────────────────────────────────────────────────────────────────────
sudo apt-get install -y redis-server
sudo systemctl enable redis-server
sudo systemctl start redis-server

echo "Pool Node.js: $(node --version), Redis $(redis-server --version | head -1)"

# ── Clone UNOMP ───────────────────────────────────────────────────────────────
sudo mkdir -p "$POOL_DIR"
sudo chown "$USER":"$USER" "$POOL_DIR"

git config --global --add safe.directory "$POOL_DIR" 2>/dev/null || true

# Reclone if the wrong repo is there (node-merged-pool library vs portal)
if [ -d "$POOL_DIR/.git" ]; then
    CURRENT_ORIGIN=$(git -C "$POOL_DIR" remote get-url origin 2>/dev/null || echo "")
    if [[ "$CURRENT_ORIGIN" != *"unified-node-open-mining-portal"* ]]; then
        echo "Wrong repo at $POOL_DIR ($CURRENT_ORIGIN) — replacing with UNOMP portal"
        sudo rm -rf "$POOL_DIR"
        sudo mkdir -p "$POOL_DIR"
        sudo chown "$USER":"$USER" "$POOL_DIR"
    fi
fi

if [ ! -d "$POOL_DIR/.git" ]; then
    git clone https://github.com/UNOMP/unified-node-open-mining-portal "$POOL_DIR"
fi

cd "$POOL_DIR"
git pull --ff-only

# Skip native addon compilation entirely — unomp-multi-hashing uses the Node 0.10
# V8 API which was removed in Node 12. We provide a pure-JS scrypt replacement below.
npm install --ignore-scripts

# ── Pure-JS scrypt replacement for unomp-multi-hashing ────────────────────────
# Write the replacement at the hoisted (top-level) location and also the nested
# location inside node-merged-pool in case npm did not hoist it.
_install_mhash() {
    local dir="$1"
    mkdir -p "$dir"
    cat > "$dir/index.js" <<'JSEOF'
'use strict';
const crypto = require('crypto');
// Litecoin/Defcoin scrypt: password=data, salt=data, N=1024, r=1, p=1, dkLen=32
function scrypt(data) {
    return crypto.scryptSync(data, data, 32, { N: 1024, r: 1, p: 1, maxmem: 256 * 1024 });
}
module.exports = { scrypt };
JSEOF
    printf '{"name":"unomp-multi-hashing","version":"0.1.0","main":"index.js"}\n' > "$dir/package.json"
}

_install_mhash "$POOL_DIR/node_modules/unomp-multi-hashing"
NESTED="$POOL_DIR/node_modules/node-merged-pool/node_modules/unomp-multi-hashing"
if [ -d "$POOL_DIR/node_modules/node-merged-pool" ]; then
    _install_mhash "$NESTED"
fi
echo "Pure-JS unomp-multi-hashing replacement installed"

# ── Pure-JS bignum replacement ────────────────────────────────────────────────
# bignum also uses a pre-NAN V8 API and won't compile on Node 16.
# Replace with a BigInt-backed implementation of the same API.
BIGNUM_DIR="$POOL_DIR/node_modules/bignum"
mkdir -p "$BIGNUM_DIR"

cat > "$BIGNUM_DIR/index.js" <<'JSEOF'
'use strict';
/* Pure-JS bignum replacement using Node.js built-in BigInt. */
class BigNum {
    constructor() { this._n = 0n; this._neg = false; }
    _s() { return this._neg ? -this._n : this._n; }
}
function _mk(v, neg) { const b = new BigNum(); b._n = v < 0n ? -v : v; b._neg = neg || v < 0n; return b; }
function bignum(val, base) {
    const b = new BigNum();
    if (typeof val === 'bigint') { b._neg = val < 0n; b._n = val < 0n ? -val : val; }
    else if (Buffer.isBuffer(val)) { const h = val.toString('hex'); b._n = h ? BigInt('0x'+h) : 0n; }
    else if (typeof val === 'number') { b._neg = val < 0; b._n = BigInt(Math.abs(Math.trunc(val))); }
    else if (typeof val === 'string') {
        const neg = val.startsWith('-'); const s = neg ? val.slice(1) : val;
        b._n = base === 16 ? BigInt('0x'+(s||'0')) : BigInt(s||'0');
        b._neg = neg;
    }
    return b;
}
// CRITICAL: honor endian option — without this, little-endian scrypt hashes are
// read as huge numbers, making share difficulty near-zero (all shares rejected).
bignum.fromBuffer = function(buf, opts) {
    const b = new BigNum();
    let data = buf;
    if (opts && opts.endian === 'little') data = Buffer.from(buf).reverse();
    const h = data.toString('hex');
    b._n = h ? BigInt('0x'+h) : 0n;
    return b;
};
const P = BigNum.prototype;
P.toString = function(base) { return (this._neg?'-':'')+this._n.toString(base===16?16:10); };
P.toBuffer = function(opts) {
    let h = this._n.toString(16); if (h.length%2) h='0'+h;
    let buf = Buffer.from(h,'hex');
    if (opts&&opts.size) { const o=Buffer.alloc(opts.size,0); const s=opts.size-buf.length; if(s>=0)buf.copy(o,s); else buf.copy(o,0,-s); return o; }
    return buf;
};
P.toNumber = function() { return Number(this._s()); };
P.add = function(o) { return _mk(this._s()+(o instanceof BigNum?o._s():BigInt(o))); };
P.sub = function(o) { return _mk(this._s()-(o instanceof BigNum?o._s():BigInt(o))); };
P.mul = function(o) { return _mk(this._s()*(o instanceof BigNum?o._s():BigInt(o))); };
P.div = function(o) { return _mk(this._s()/(o instanceof BigNum?o._s():BigInt(o))); };
P.mod = function(o) { return _mk(this._n%(o instanceof BigNum?o._n:BigInt(o))); };
P.shiftLeft = function(n) { return _mk(this._s()<<BigInt(n)); };
P.shiftRight = function(n) { return _mk(this._s()>>BigInt(n)); };
P.and = function(o) { return _mk(this._n&(o instanceof BigNum?o._n:BigInt(o))); };
P.or  = function(o) { return _mk(this._n|(o instanceof BigNum?o._n:BigInt(o))); };
P.xor = function(o) { return _mk(this._n^(o instanceof BigNum?o._n:BigInt(o))); };
P.not = function() { return _mk(~this._s()); };
P.neg = function() { return _mk(-this._s()); };
P.abs = function() { return _mk(this._n); };
P.isZero = function() { return this._n===0n; };
P.gt = function(o) { return this._s()>(o instanceof BigNum?o._s():BigInt(o)); };
P.lt = function(o) { return this._s()<(o instanceof BigNum?o._s():BigInt(o)); };
P.ge = function(o) { return this._s()>=(o instanceof BigNum?o._s():BigInt(o)); };
P.le = function(o) { return this._s()<=(o instanceof BigNum?o._s():BigInt(o)); };
P.eq = function(o) { return this._s()===(o instanceof BigNum?o._s():BigInt(o)); };
P.cmp = function(o) { const a=this._s(),b=(o instanceof BigNum?o._s():BigInt(o)); return a>b?1:a<b?-1:0; };
P.setcompact = function(bits) {
    const n=BigInt(bits>>>0); const size=Number(n>>24n); const word=n&0x7fffffn;
    this._n = size<=3 ? word>>BigInt((3-size)*8) : word<<BigInt((size-3)*8);
    this._neg = (n&0x800000n)!==0n; return this;
};
P.pow = function(e) { return _mk(this._s()**BigInt(e)); };
P.jacobi = function() { return 0; };
// Allow JSON.stringify — native BigInt in _n would throw "Do not know how to serialize a BigInt"
P.toJSON = function() { return this._n.toString(); };
module.exports = bignum;
JSEOF

printf '{"name":"bignum","version":"0.13.1","main":"index.js"}\n' > "$BIGNUM_DIR/package.json"

# Always install in merged-pooler's nested node_modules — it has its own bignum
# that takes precedence over the top-level one and must also be patched.
NESTED_BN="$POOL_DIR/node_modules/merged-pooler/node_modules/bignum"
if [ -d "$POOL_DIR/node_modules/merged-pooler" ]; then
    mkdir -p "$NESTED_BN"
    cp "$BIGNUM_DIR/index.js" "$NESTED_BN/"
    cp "$BIGNUM_DIR/package.json" "$NESTED_BN/"
fi
echo "Pure-JS bignum replacement installed"

# ── Pool coin config ──────────────────────────────────────────────────────────
mkdir -p "$POOL_DIR/coins"
cat > "$POOL_DIR/coins/defcoin.json" <<EOF
{
    "name": "Defcoin",
    "symbol": "DFC",
    "algorithm": "scrypt",
    "nValue": 1024,
    "rValue": 1,
    "txMessages": false
}
EOF

# ── Pool config ───────────────────────────────────────────────────────────────
mkdir -p "$POOL_DIR/pool_configs"
cat > "$POOL_DIR/pool_configs/defcoin.json" <<EOF
{
    "enabled": true,
    "coin": "defcoin.json",
    "address": "${POOL_WALLET_ADDRESS}",
    "jobRebroadcastTimeout": 55,
    "connectionTimeout": 600,
    "rewardRecipients": {},
    "auxes": {},
    "paymentProcessing": {
        "enabled": true,
        "paymentInterval": 30,
        "minimumPayment": 0.5,
        "daemon": {
            "host": "127.0.0.1",
            "port": 17332,
            "user": "${RPC_USER}",
            "password": "${RPC_PASS}"
        }
    },
    "ports": {
        "3333": {
            "diff": 1,
            "varDiff": {
                "minDiff": 0.5,
                "maxDiff": 512,
                "targetTime": 15,
                "retargetTime": 60,
                "variancePercent": 30
            }
        }
    },
    "daemons": [
        {
            "host": "127.0.0.1",
            "port": 17332,
            "user": "${RPC_USER}",
            "password": "${RPC_PASS}"
        }
    ],
    "p2p": {
        "enabled": false
    },
    "mposMode": {
        "enabled": false
    }
}
EOF

# ── Portal config (website + API) ─────────────────────────────────────────────
cat > "$POOL_DIR/config.json" <<EOF
{
    "logLevel": "debug",
    "logColors": true,
    "cliAddress": "0.0.0.0",
    "cliPort": 17323,
    "redis": {
        "host": "127.0.0.1",
        "port": 6379
    },
    "website": {
        "enabled": true,
        "host": "0.0.0.0",
        "port": 8080,
        "stratumHost": "${POOL_DOMAIN}",
        "stats": {
            "updateInterval": 60,
            "historicalRetention": 43200,
            "hashrateWindow": 300
        },
        "adminPassword": "CHANGE_ME_ADMIN_PASS",
        "siteTitle": "Defcoin Mining Pool"
    },
    "switching": {
        "switch1": {
            "enabled": false,
            "algorithm": "scrypt",
            "ports": { "3333": { "diff": 64 } }
        }
    },
    "poolServer": {
        "enabled": true,
        "mergedMining": false
    }
}
EOF

# ── Apply compatibility patches ───────────────────────────────────────────────
echo "=== Applying merged-pooler / UNOMP patches ==="
POOL_DIR="$POOL_DIR" bash "$SCRIPT_DIR/patches/apply-patches.sh"

echo ""
echo "=== Pool setup complete ==="
echo "Test with: cd $POOL_DIR && node init.js"
echo "Miners connect to: stratum+tcp://${POOL_DOMAIN}:3333"
echo ""
echo "IMPORTANT: Edit $POOL_DIR/config.json and change 'CHANGE_ME_ADMIN_PASS'"
