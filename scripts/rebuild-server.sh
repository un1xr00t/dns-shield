# /scripts/rebuild-server.sh
#!/bin/bash

# ===========================================
# Server Hardening Setup Script
# ===========================================
# Run as root on a fresh Debian 12 / Ubuntu 24 server

set -e

# Load configuration
if [ -f "config.env" ]; then
    source config.env
else
    echo "ERROR: config.env not found. Copy config.env.example to config.env and configure."
    exit 1
fi

echo "=========================================="
echo "  Server Hardening Setup"
echo "=========================================="
echo ""
echo "Domain: $DOMAIN"
echo "Server IP: $SERVER_IP"
echo ""

# -------------------------------------------
# 1. System Updates
# -------------------------------------------
echo "[1/9] Updating system..."
apt update && apt upgrade -y

# -------------------------------------------
# 2. Install Required Packages
# -------------------------------------------
echo "[2/9] Installing packages..."
apt install -y nginx fail2ban ufw curl

# -------------------------------------------
# 3. Configure UFW Firewall
# -------------------------------------------
echo "[3/9] Configuring firewall..."
ufw default deny incoming
ufw default allow outgoing
ufw allow $SSH_PORT/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

# -------------------------------------------
# 4. Configure Swap
# -------------------------------------------
echo "[4/9] Configuring swap..."
if [ ! -f /swapfile ]; then
    fallocate -l $SWAP_SIZE /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
sysctl vm.swappiness=$SWAPPINESS
echo "vm.swappiness=$SWAPPINESS" >> /etc/sysctl.conf

# -------------------------------------------
# 5. Generate Dummy SSL Certificate
# -------------------------------------------
echo "[5/9] Generating dummy SSL certificate..."
mkdir -p /etc/nginx/ssl
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout /etc/nginx/ssl/dummy.key \
    -out /etc/nginx/ssl/dummy.crt \
    -subj "/C=US/ST=State/L=City/O=Org/CN=localhost"

# -------------------------------------------
# 6. Configure nginx
# -------------------------------------------
echo "[6/9] Configuring nginx..."

# Backup original config
cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.backup

# Copy nginx config
cp nginx/nginx.conf /etc/nginx/nginx.conf

# Create site config from template
sed -e "s/{{DOMAIN}}/$DOMAIN/g" \
    -e "s/{{WWW_DOMAIN}}/$WWW_DOMAIN/g" \
    -e "s/{{WEBSITE_DIST}}/${WEBSITE_DIST//\//\\/}/g" \
    nginx/site.conf.example > /etc/nginx/sites-available/$DOMAIN.conf

ln -sf /etc/nginx/sites-available/$DOMAIN.conf /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

# Create log file for unknown hosts if it doesn't exist
touch /var/log/nginx/unknown-hosts.log
chown www-data:adm /var/log/nginx/unknown-hosts.log

nginx -t && systemctl reload nginx

# -------------------------------------------
# 7. Configure fail2ban
# -------------------------------------------
echo "[7/9] Configuring fail2ban..."

# Copy filter
cp fail2ban/filter.d/nginx-badbots.conf /etc/fail2ban/filter.d/

# Create jail configs with variables
sed -e "s/{{SSH_MAXRETRY}}/${SSH_MAXRETRY:-3}/g" \
    -e "s/{{SSH_BANTIME}}/${SSH_BANTIME:-3600}/g" \
    fail2ban/jail.d/sshd.conf > /etc/fail2ban/jail.d/sshd.conf

sed -e "s/{{BOT_BANTIME}}/${BOT_BANTIME:-86400}/g" \
    fail2ban/jail.d/nginx-badbots.conf > /etc/fail2ban/jail.d/nginx-badbots.conf

systemctl restart fail2ban

# -------------------------------------------
# 8. Harden SSH
# -------------------------------------------
echo "[8/9] Hardening SSH..."
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl restart ssh

# -------------------------------------------
# 9. Prepare for Monitoring
# -------------------------------------------
echo "[9/9] Preparing for monitoring..."

# Create log file for fail2ban aggregation
touch /var/log/fail2ban-bans.log
chmod 644 /var/log/fail2ban-bans.log

# Create scripts directory if needed
mkdir -p /usr/local/bin

echo ""
echo "=========================================="
echo "  Setup Complete!"
echo "=========================================="
echo ""
echo "Next steps:"
echo "1. Upload your website to $WEBSITE_DIST"
echo "2. Set up SSL with: certbot --nginx -d $DOMAIN -d $WWW_DOMAIN"
echo "3. (Optional) Run ./scripts/setup-monitoring.sh for alerts"
echo ""
echo "Verify:"
echo "  nginx -t"
echo "  fail2ban-client status"
echo "  ufw status"
echo ""
echo "Log files created:"
echo "  /var/log/nginx/unknown-hosts.log  - DNS pointing attempts"
echo "  /var/log/fail2ban-bans.log        - Ban aggregation log"
echo ""
