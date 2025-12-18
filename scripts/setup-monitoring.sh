#!/bin/bash

# ===========================================
# Server Monitoring Setup Script
# ===========================================
# Sets up real-time alerts via n8n -> Discord

set -e

# Load configuration
if [ -f "config.env" ]; then
    source config.env
else
    echo "ERROR: config.env not found"
    exit 1
fi

if [ -z "$N8N_WEBHOOK_URL" ]; then
    echo "ERROR: N8N_WEBHOOK_URL not set in config.env"
    exit 1
fi

echo "=========================================="
echo "  Monitoring Setup"
echo "=========================================="
echo ""

# Save webhook URL
echo "$N8N_WEBHOOK_URL" > /root/.n8n-webhook
chmod 600 /root/.n8n-webhook

# -------------------------------------------
# 1. Base Alert Script
# -------------------------------------------
echo "[1/5] Creating base alert script..."

cat > /usr/local/bin/n8n-alert.sh << 'EOF'
#!/bin/bash
WEBHOOK=$(cat /root/.n8n-webhook)
TYPE="$1"
MESSAGE="$2"
IP="$3"
EXTRA="$4"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

curl -s -X POST "$WEBHOOK" \
  -H "Content-Type: application/json" \
  -d "{\"type\":\"$TYPE\",\"message\":\"$MESSAGE\",\"ip\":\"$IP\",\"extra\":\"$EXTRA\",\"timestamp\":\"$TIMESTAMP\"}" \
  > /dev/null 2>&1
EOF
chmod +x /usr/local/bin/n8n-alert.sh

# -------------------------------------------
# 2. SSH Login Alert
# -------------------------------------------
echo "[2/5] Creating SSH login alert..."

cat > /usr/local/bin/ssh-login-alert.sh << 'EOF'
#!/bin/bash
if [ "$PAM_TYPE" = "open_session" ]; then
    WEBHOOK=$(cat /root/.n8n-webhook)
    TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    curl -s -X POST "$WEBHOOK" \
      -H "Content-Type: application/json" \
      -d "{\"type\":\"ssh_login\",\"message\":\"SSH login detected\",\"user\":\"$PAM_USER\",\"ip\":\"$PAM_RHOST\",\"timestamp\":\"$TIMESTAMP\"}" \
      > /dev/null 2>&1
fi
EOF
chmod +x /usr/local/bin/ssh-login-alert.sh

# Add to PAM if not already there
if ! grep -q "ssh-login-alert" /etc/pam.d/sshd; then
    echo "session optional pam_exec.so /usr/local/bin/ssh-login-alert.sh" >> /etc/pam.d/sshd
fi

# -------------------------------------------
# 3. fail2ban Alert
# -------------------------------------------
echo "[3/5] Creating fail2ban alert..."

cat > /usr/local/bin/fail2ban-alert.sh << 'EOF'
#!/bin/bash
WEBHOOK=$(cat /root/.n8n-webhook)
JAIL="$1"
IP="$2"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

curl -s -X POST "$WEBHOOK" \
  -H "Content-Type: application/json" \
  -d "{\"type\":\"fail2ban\",\"message\":\"IP banned by fail2ban\",\"jail\":\"$JAIL\",\"ip\":\"$IP\",\"timestamp\":\"$TIMESTAMP\"}" \
  > /dev/null 2>&1
EOF
chmod +x /usr/local/bin/fail2ban-alert.sh

# Create fail2ban action
cp fail2ban/action.d/n8n-notify.conf /etc/fail2ban/action.d/

# Update jails to use notification
cat > /etc/fail2ban/jail.d/n8n-alerts.conf << EOF
[sshd]
action = %(action_)s
         n8n-notify

[nginx-badbots]
action = %(action_)s
         n8n-notify
EOF

# -------------------------------------------
# 4. Unknown Host Monitor (DNS Pointing)
# -------------------------------------------
echo "[4/5] Creating DNS pointing monitor..."

cat > /usr/local/bin/unknown-host-monitor.sh << 'EOF'
#!/bin/bash
WEBHOOK=$(cat /root/.n8n-webhook)
LOGFILE="/var/log/nginx/unknown-hosts.log"
LASTCHECK="/tmp/unknown-hosts-lastpos"

if [ -f "$LASTCHECK" ]; then
    LASTPOS=$(cat "$LASTCHECK")
else
    LASTPOS=0
fi

CURSIZE=$(stat -c%s "$LOGFILE" 2>/dev/null || echo 0)

if [ "$CURSIZE" -lt "$LASTPOS" ]; then
    LASTPOS=0
fi

if [ "$CURSIZE" -gt "$LASTPOS" ]; then
    tail -c +$((LASTPOS + 1)) "$LOGFILE" | while read line; do
        IP=$(echo "$line" | awk '{print $1}')
        HOST=$(echo "$line" | awk -F'Host: "' '{print $2}' | awk -F'"' '{print $1}')
        TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        
        if [ -z "$HOST" ]; then
            HOST="unknown"
        fi
        
        curl -s -X POST "$WEBHOOK" \
          -H "Content-Type: application/json" \
          -d "{\"type\":\"unknown_host\",\"message\":\"DNS pointing attempt blocked\",\"ip\":\"$IP\",\"host\":\"$HOST\",\"timestamp\":\"$TIMESTAMP\"}" \
          > /dev/null 2>&1
    done
fi

echo "$CURSIZE" > "$LASTCHECK"
EOF
chmod +x /usr/local/bin/unknown-host-monitor.sh

# Add cron job
if ! crontab -l 2>/dev/null | grep -q "unknown-host-monitor"; then
    (crontab -l 2>/dev/null; echo "*/5 * * * * /usr/local/bin/unknown-host-monitor.sh") | crontab -
fi

# -------------------------------------------
# 5. Daily Summary
# -------------------------------------------
echo "[5/5] Creating daily summary..."

cat > /usr/local/bin/daily-summary.sh << 'EOF'
#!/bin/bash
WEBHOOK=$(cat /root/.n8n-webhook)
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

FAILED_SSH=$(grep "Failed password" /var/log/auth.log 2>/dev/null | grep "$(date +%b\ %d)" | wc -l)
SSHD_BANS=$(fail2ban-client status sshd 2>/dev/null | grep "Currently banned" | awk '{print $NF}')
BOT_BANS=$(fail2ban-client status nginx-badbots 2>/dev/null | grep "Currently banned" | awk '{print $NF}')
UNKNOWN_HOSTS=$(wc -l < /var/log/nginx/unknown-hosts.log 2>/dev/null || echo 0)
TOTAL_REQUESTS=$(wc -l < /var/log/nginx/access.log 2>/dev/null || echo 0)
BLOCKED_REQUESTS=$(grep -c "\" 403 \|\" 444 " /var/log/nginx/access.log 2>/dev/null || echo 0)

curl -s -X POST "$WEBHOOK" \
  -H "Content-Type: application/json" \
  -d "{\"type\":\"daily_summary\",\"failed_ssh\":$FAILED_SSH,\"sshd_bans\":${SSHD_BANS:-0},\"bot_bans\":${BOT_BANS:-0},\"unknown_hosts\":$UNKNOWN_HOSTS,\"total_requests\":$TOTAL_REQUESTS,\"blocked_requests\":$BLOCKED_REQUESTS,\"timestamp\":\"$TIMESTAMP\"}" \
  > /dev/null 2>&1
EOF
chmod +x /usr/local/bin/daily-summary.sh

# Add daily cron
if ! crontab -l 2>/dev/null | grep -q "daily-summary"; then
    (crontab -l 2>/dev/null; echo "0 9 * * * /usr/local/bin/daily-summary.sh") | crontab -
fi

# Restart fail2ban
systemctl restart fail2ban

echo ""
echo "=========================================="
echo "  Monitoring Setup Complete!"
echo "=========================================="
echo ""
echo "Alerts configured:"
echo "  - SSH logins (instant)"
echo "  - fail2ban bans (instant)"
echo "  - DNS pointing attempts (every 5 min)"
echo "  - Daily summary (9 AM UTC)"
echo ""
echo "Test with:"
echo "  /usr/local/bin/n8n-alert.sh test 'Test alert' '127.0.0.1'"
echo ""
