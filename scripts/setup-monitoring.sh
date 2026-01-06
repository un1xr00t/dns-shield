# /scripts/setup-monitoring.sh
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
echo "[1/7] Creating base alert script..."

cat > /usr/local/bin/n8n-alert.sh << 'EOF'
#!/bin/bash
# /usr/local/bin/n8n-alert.sh
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
echo "[2/7] Creating SSH login alert..."

cat > /usr/local/bin/ssh-login-alert.sh << 'EOF'
#!/bin/bash
# /usr/local/bin/ssh-login-alert.sh
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
# 3. fail2ban Alert (Logs to file for aggregation)
# -------------------------------------------
echo "[3/7] Creating fail2ban alert (aggregated)..."

cat > /usr/local/bin/fail2ban-alert.sh << 'EOF'
#!/bin/bash
# /usr/local/bin/fail2ban-alert.sh
# Logs bans to file for aggregation instead of instant Discord spam

JAIL="$1"
IP="$2"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
BAN_LOG="/var/log/fail2ban-bans.log"

# Log the ban for later aggregation
echo "${TIMESTAMP}|${JAIL}|${IP}" >> "$BAN_LOG"
EOF
chmod +x /usr/local/bin/fail2ban-alert.sh

# -------------------------------------------
# 4. fail2ban Summary (Aggregated alerts)
# -------------------------------------------
echo "[4/7] Creating fail2ban summary..."

cat > /usr/local/bin/fail2ban-summary.sh << 'EOF'
#!/bin/bash
# /usr/local/bin/fail2ban-summary.sh
# Sends aggregated ban alerts every 30 minutes

WEBHOOK=$(cat /root/.n8n-webhook)
BAN_LOG="/var/log/fail2ban-bans.log"
LAST_RUN="/tmp/fail2ban-summary-lastrun"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Exit if no ban log exists
if [[ ! -f "$BAN_LOG" ]]; then
    exit 0
fi

# Get last run timestamp (or epoch if first run)
if [[ -f "$LAST_RUN" ]]; then
    LAST_TIMESTAMP=$(cat "$LAST_RUN")
else
    LAST_TIMESTAMP="1970-01-01T00:00:00Z"
fi

# Count bans since last run
SSHD_COUNT=0
BOTBAN_COUNT=0
OTHER_COUNT=0
TOTAL_COUNT=0
IP_LIST=""

while IFS='|' read -r ban_time jail ip; do
    # Skip if before last run
    if [[ "$ban_time" < "$LAST_TIMESTAMP" ]]; then
        continue
    fi
    
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    
    case "$jail" in
        sshd)
            SSHD_COUNT=$((SSHD_COUNT + 1))
            ;;
        nginx-badbots)
            BOTBAN_COUNT=$((BOTBAN_COUNT + 1))
            ;;
        *)
            OTHER_COUNT=$((OTHER_COUNT + 1))
            ;;
    esac
    
    # Collect unique IPs (max 10 for display)
    if [[ $TOTAL_COUNT -le 10 ]]; then
        IP_LIST="${IP_LIST}${ip} (${jail}), "
    fi
done < "$BAN_LOG"

# Save current timestamp for next run
echo "$TIMESTAMP" > "$LAST_RUN"

# Exit if no new bans
if [[ $TOTAL_COUNT -eq 0 ]]; then
    exit 0
fi

# Trim trailing comma from IP list
IP_LIST=${IP_LIST%, }

# Add "and X more" if over 10
if [[ $TOTAL_COUNT -gt 10 ]]; then
    EXTRA=$((TOTAL_COUNT - 10))
    IP_LIST="${IP_LIST}, +${EXTRA} more"
fi

# Build summary message
MESSAGE="**${TOTAL_COUNT} IPs banned** in the last period"
BREAKDOWN="sshd: ${SSHD_COUNT}, nginx-badbots: ${BOTBAN_COUNT}"
if [[ $OTHER_COUNT -gt 0 ]]; then
    BREAKDOWN="${BREAKDOWN}, other: ${OTHER_COUNT}"
fi

# Send to n8n
curl -s -X POST "$WEBHOOK" \
  -H "Content-Type: application/json" \
  -d "{\"type\":\"fail2ban_summary\",\"message\":\"${MESSAGE}\",\"breakdown\":\"${BREAKDOWN}\",\"sample_ips\":\"${IP_LIST}\",\"sshd_count\":${SSHD_COUNT},\"bot_count\":${BOTBAN_COUNT},\"total_count\":${TOTAL_COUNT},\"timestamp\":\"${TIMESTAMP}\"}" \
  > /dev/null 2>&1

# Rotate log if it gets too big (over 10000 lines)
LOG_LINES=$(wc -l < "$BAN_LOG")
if [[ $LOG_LINES -gt 10000 ]]; then
    tail -5000 "$BAN_LOG" > "${BAN_LOG}.tmp"
    mv "${BAN_LOG}.tmp" "$BAN_LOG"
fi
EOF
chmod +x /usr/local/bin/fail2ban-summary.sh

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
# 5. Unknown Host Monitor (DNS Pointing)
# -------------------------------------------
echo "[5/7] Creating DNS pointing monitor..."

cat > /usr/local/bin/unknown-host-monitor.sh << 'EOF'
#!/bin/bash
# /usr/local/bin/unknown-host-monitor.sh
WEBHOOK=$(cat /root/.n8n-webhook)
LOGFILE="/var/log/nginx/unknown-hosts.log"
LASTCHECK="/tmp/unknown-hosts-lastpos"
MY_IP="${SERVER_IP:-127.0.0.1}"

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
        
        # Skip scanner noise: empty, underscore, unknown, localhost, IP addresses
        if [ -z "$HOST" ] || [ "$HOST" = "_" ] || [ "$HOST" = "unknown" ] || [ "$HOST" = "$MY_IP" ] || [ "$HOST" = "localhost" ]; then
            continue
        fi
        
        # Skip if Host header looks like an IP address
        if echo "$HOST" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
            continue
        fi
        
        # Skip binary garbage (TLS handshakes hitting HTTP port)
        if echo "$HOST" | grep -q '\\x'; then
            continue
        fi
        
        # This is a real domain - alert!
        curl -s -X POST "$WEBHOOK" \
          -H "Content-Type: application/json" \
          -d "{\"type\":\"unknown_host\",\"message\":\"DNS pointing attempt blocked\",\"ip\":\"$IP\",\"host\":\"$HOST\",\"timestamp\":\"$TIMESTAMP\"}" \
          > /dev/null 2>&1
    done
fi

echo "$CURSIZE" > "$LASTCHECK"
EOF
chmod +x /usr/local/bin/unknown-host-monitor.sh

# Add cron job for unknown host monitor
if ! crontab -l 2>/dev/null | grep -q "unknown-host-monitor"; then
    (crontab -l 2>/dev/null; echo "*/5 * * * * /usr/local/bin/unknown-host-monitor.sh") | crontab -
fi

# -------------------------------------------
# 6. Daily Summary
# -------------------------------------------
echo "[6/7] Creating daily summary..."

cat > /usr/local/bin/daily-summary.sh << 'EOF'
#!/bin/bash
# /usr/local/bin/daily-summary.sh
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

# -------------------------------------------
# 7. Add fail2ban summary cron
# -------------------------------------------
echo "[7/7] Adding fail2ban summary cron..."

if ! crontab -l 2>/dev/null | grep -q "fail2ban-summary"; then
    (crontab -l 2>/dev/null; echo "*/30 * * * * /usr/local/bin/fail2ban-summary.sh") | crontab -
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
echo "  - fail2ban bans (aggregated every 30 min)"
echo "  - DNS pointing attempts (every 5 min)"
echo "  - Daily summary (9 AM UTC)"
echo ""
echo "Cron jobs:"
echo "  */5 * * * *  - unknown-host-monitor.sh"
echo "  */30 * * * * - fail2ban-summary.sh"
echo "  0 9 * * *    - daily-summary.sh"
echo ""
echo "Test with:"
echo "  /usr/local/bin/n8n-alert.sh test 'Test alert' '127.0.0.1'"
echo ""
echo "Scripts created:"
echo "  /usr/local/bin/n8n-alert.sh"
echo "  /usr/local/bin/ssh-login-alert.sh"
echo "  /usr/local/bin/fail2ban-alert.sh"
echo "  /usr/local/bin/fail2ban-summary.sh"
echo "  /usr/local/bin/unknown-host-monitor.sh"
echo "  /usr/local/bin/daily-summary.sh"
echo ""
