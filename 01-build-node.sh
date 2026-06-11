#!/usr/bin/env bash
set -euo pipefail

echo "=== Phase 2: Building Defcoin-Core-Nu node ==="

# ── Dependencies ──────────────────────────────────────────────────────────────
sudo apt-get install -y \
    build-essential libtool autotools-dev automake pkg-config \
    libssl-dev libevent-dev bsdmainutils \
    libboost-system-dev libboost-filesystem-dev libboost-chrono-dev \
    libboost-program-options-dev libboost-test-dev libboost-thread-dev \
    libsqlite3-dev libzmq3-dev libfmt-dev \
    git curl wget

# Build Berkeley DB 4.8 from source — the bitcoin PPA is dead on Ubuntu 22.04
# and Defcoin-Core-Nu still requires BDB for wallet functionality.
BDB_PREFIX="$HOME/bdb4.8"
if [ ! -f "$BDB_PREFIX/lib/libdb_cxx-4.8.a" ]; then
    cd /tmp
    wget -q https://download.oracle.com/berkeley-db/db-4.8.30.NC.tar.gz
    tar -xzf db-4.8.30.NC.tar.gz
    cd db-4.8.30.NC/build_unix
    mkdir -p "$BDB_PREFIX"
    sed -i 's/__atomic_compare_exchange/__atomic_compare_exchange_db/g' \
        ../dbinc/atomic.h
    ../dist/configure \
        --enable-cxx \
        --disable-shared \
        --with-pic \
        --prefix="$BDB_PREFIX"
    make -j"$(nproc)"
    make install
    cd /tmp && rm -rf db-4.8.30.NC db-4.8.30.NC.tar.gz
    echo "BDB 4.8 built at $BDB_PREFIX"
fi

# ── Build defcoind ────────────────────────────────────────────────────────────
DEFCOIN_REPO="$HOME/Defcoin-Core-Nu"
DEFCOIN_SRC="$DEFCOIN_REPO/source"

if [ ! -d "$DEFCOIN_REPO" ]; then
    git clone https://github.com/defcoincore/Defcoin-Core-Nu "$DEFCOIN_REPO"
fi

cd "$DEFCOIN_REPO" && git pull --ff-only
cd "$DEFCOIN_SRC"

./autogen.sh
./configure \
    --disable-tests \
    --disable-bench \
    --without-gui \
    --disable-man \
    BDB_LIBS="-L${BDB_PREFIX}/lib -ldb_cxx-4.8" \
    BDB_CFLAGS="-I${BDB_PREFIX}/include"
make -j"$(nproc)"
sudo make install

echo "defcoind installed: $(which defcoind)"

# ── Create data dir and config ────────────────────────────────────────────────
mkdir -p "$DEFCOIN_DIR"
chmod 700 "$DEFCOIN_DIR"

cat > "$DEFCOIN_DIR/defcoin.conf" <<EOF
daemon=1
server=1
txindex=1

rpcuser=${RPC_USER}
rpcpassword=${RPC_PASS}
rpcallowip=127.0.0.1
rpcport=17332

# P2P port (must be open in Azure NSG)
port=17333

# Index all transactions (required by eIquidus)
txindex=1

# Known live peers — add IPs here if DNS seeders are dead
# addnode=x.x.x.x
EOF

chmod 600 "$DEFCOIN_DIR/defcoin.conf"
echo "defcoin.conf written to $DEFCOIN_DIR"

echo ""
echo "=== Node build complete ==="
echo "Start with: defcoind -daemon"
echo "Check sync: defcoin-cli getblockchaininfo"
echo ""
echo "NOTE: If 'getpeerinfo' returns [], the DNS seeders may be dead."
echo "Find live peers at defcoin.host and add 'addnode=<ip>' lines to defcoin.conf"
