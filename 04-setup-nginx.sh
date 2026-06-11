#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export HOME="${HOME:-$(getent passwd "$(id -un)" | cut -d: -f6)}"
export USER="${USER:-$(id -un)}"
set +u
[ -f "$SCRIPT_DIR/vars.sh" ] && . "$SCRIPT_DIR/vars.sh"
set -u

echo "=== Phase 5: Setting up nginx + SSL ==="

sudo apt-get install -y nginx certbot python3-certbot-nginx

# ── Explorer vhost ────────────────────────────────────────────────────────────
sudo tee /etc/nginx/sites-available/defcoin-explorer > /dev/null <<EOF
server {
    listen 80;
    server_name ${EXPLORER_DOMAIN};

    location / {
        proxy_pass http://127.0.0.1:3001;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOF

# ── Pool vhost ────────────────────────────────────────────────────────────────
sudo tee /etc/nginx/sites-available/defcoin-pool > /dev/null <<EOF
server {
    listen 80;
    server_name ${POOL_DOMAIN};

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOF

sudo ln -sf /etc/nginx/sites-available/defcoin-explorer /etc/nginx/sites-enabled/
sudo ln -sf /etc/nginx/sites-available/defcoin-pool /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default

sudo nginx -t
sudo systemctl reload nginx

# ── SSL (skipped if using raw IP instead of domain) ───────────────────────────
# If EXPLORER_DOMAIN or POOL_DOMAIN look like IPs, skip certbot
is_ip() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

if is_ip "$EXPLORER_DOMAIN" || is_ip "$POOL_DOMAIN"; then
    echo ""
    echo "WARNING: You're using IP addresses instead of domain names."
    echo "Skipping SSL — Let's Encrypt requires real domain names."
    echo "Access explorer at http://${EXPLORER_DOMAIN} and pool at http://${POOL_DOMAIN}"
else
    sudo certbot --nginx \
        --non-interactive \
        --agree-tos \
        --email "${CERTBOT_EMAIL}" \
        -d "${EXPLORER_DOMAIN}" \
        -d "${POOL_DOMAIN}"
    echo "SSL certificates issued for ${EXPLORER_DOMAIN} and ${POOL_DOMAIN}"
fi

echo ""
echo "=== nginx setup complete ==="
