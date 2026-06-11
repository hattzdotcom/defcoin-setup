#!/usr/bin/env bash
# vars.sh — fill in these values before running install.sh

# RPC credentials (used by defcoind, pool, and explorer — must all match)
export RPC_USER="defcoinrpc"
export RPC_PASS="CHANGE_ME_STRONG_PASSWORD"

# The wallet address that receives mining pool block rewards
export POOL_WALLET_ADDRESS="CHANGE_ME_YOUR_DEFCOIN_ADDRESS"

# Domain names for nginx/SSL (set to server IP if you have no domain)
export EXPLORER_DOMAIN="explorer.yourdomain.com"
export POOL_DOMAIN="pool.yourdomain.com"

# Email for Let's Encrypt cert registration
export CERTBOT_EMAIL="CHANGE_ME_YOUR_EMAIL"

# defcoin data directory
export DEFCOIN_DIR="$HOME/.defcoin"

# Install roots (scripts create these)
export POOL_DIR="/opt/defcoin-pool"
export EXPLORER_DIR="/opt/defcoin-explorer"
