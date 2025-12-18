# Server Maintenance Guide

## Daily Checks (Automated)

The daily summary script runs at 9 AM UTC and reports:

- Failed SSH attempts
- IPs banned by fail2ban
- DNS pointing attempts blocked
- Total/blocked request counts

---

## Weekly Maintenance

### Review fail2ban Status

```bash
# Check all jails
fail2ban-client status

# Check specific jail
fail2ban-client status sshd
fail2ban-client status nginx-badbots
```

### Review DNS Pointing Attempts

```bash
# Last 100 unknown host requests
tail -100 /var/log/nginx/unknown-hosts.log

# Count by IP
awk '{print $1}' /var/log/nginx/unknown-hosts.log | sort | uniq -c | sort -rn | head -20

# Count by Host header
grep -oP 'Host: "\K[^"]+' /var/log/nginx/unknown-hosts.log | sort | uniq -c | sort -rn | head -20
```

### Review Auth Log

```bash
# Failed password attempts
grep "Failed password" /var/log/auth.log | tail -50

# Successful logins
last -20
```

---

## Monthly Maintenance

### System Updates

```bash
apt update
apt upgrade -y
apt autoremove -y
```

### Review SSH Keys

```bash
cat ~/.ssh/authorized_keys
```

### Check for Unauthorized Users

```bash
cat /etc/passwd | grep -v nologin | grep -v false
```

### Verify Cron Jobs

```bash
crontab -l
```

### Check Disk Space

```bash
df -h
```

### Check Memory

```bash
free -h
```

---

## Common Tasks

### Manually Ban an IP

```bash
# Ban in fail2ban
fail2ban-client set sshd banip 192.168.1.100

# Or permanently in UFW
ufw deny from 192.168.1.100
```

### Unban an IP

```bash
fail2ban-client set sshd unbanip 192.168.1.100
```

### Test nginx Configuration

```bash
nginx -t
```

### Reload nginx (No Downtime)

```bash
systemctl reload nginx
```

### Restart fail2ban

```bash
systemctl restart fail2ban
```

### View Real-Time Logs

```bash
# Access log
tail -f /var/log/nginx/access.log

# Error log
tail -f /var/log/nginx/error.log

# Unknown hosts (DNS pointing)
tail -f /var/log/nginx/unknown-hosts.log

# Auth log
tail -f /var/log/auth.log
```

### Test Monitoring Alert

```bash
/usr/local/bin/n8n-alert.sh test "Test alert message" "127.0.0.1"
```

### Run Daily Summary Manually

```bash
/usr/local/bin/daily-summary.sh
```

---

## Backup Procedures

### Create Full Backup

```bash
#!/bin/bash
DATE=$(date +%Y%m%d)
BACKUP_DIR="/root/backups/$DATE"
mkdir -p $BACKUP_DIR

# Website
tar -czvf $BACKUP_DIR/website.tar.gz -C /var/www html/

# nginx config
tar -czvf $BACKUP_DIR/nginx.tar.gz -C /etc nginx/

# fail2ban config
tar -czvf $BACKUP_DIR/fail2ban.tar.gz -C /etc fail2ban/

# SSL certs
tar -czvf $BACKUP_DIR/ssl.tar.gz -C /etc/nginx ssl/

# Monitoring scripts
tar -czvf $BACKUP_DIR/scripts.tar.gz -C /usr/local bin/

echo "Backup complete: $BACKUP_DIR"
```

### Download Backup

From local machine:
```bash
scp -r root@YOUR_SERVER_IP:/root/backups/YYYYMMDD ~/Desktop/server-backup/
```

---

## Troubleshooting

### Website Returns 444

Your request is hitting the catch-all block. Check:
1. Is the domain configured in nginx?
2. Is DNS pointing correctly?
3. Is SSL certificate valid?

```bash
# Test with correct Host header
curl -I -H "Host: example.com" http://localhost
```

### Not Receiving Discord Alerts

1. Check webhook URL is saved:
```bash
cat /root/.n8n-webhook
```

2. Test webhook:
```bash
curl -X POST "$(cat /root/.n8n-webhook)" \
  -H "Content-Type: application/json" \
  -d '{"type":"test","message":"Test"}'
```

3. Verify n8n workflow is active

### fail2ban Not Banning

1. Check jail is enabled:
```bash
fail2ban-client status
```

2. Test filter regex:
```bash
fail2ban-regex /var/log/nginx/access.log /etc/fail2ban/filter.d/nginx-badbots.conf
```

3. Restart fail2ban:
```bash
systemctl restart fail2ban
```

### Locked Out of SSH

1. Use hosting provider's console (Linode LISH, DigitalOcean Console, etc.)

2. Temporarily enable password:
```bash
sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
systemctl restart ssh
```

3. Fix SSH key

4. Disable password again:
```bash
sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl restart ssh
```

---

## Emergency Contacts

| Service | Contact |
|---------|---------|
| Hosting Provider | Support portal |
| Domain Registrar | Abuse reporting |
| SSL Provider | Certificate issues |
