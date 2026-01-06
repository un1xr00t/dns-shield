# /path/to/repo/README.md
# Server Hardening & Monitoring Template

A comprehensive guide for hardening a Linux server against DNS pointing attacks, brute force attempts, and malicious bots. Includes real-time monitoring via n8n and Discord.

## Overview

This template provides:

- **nginx hardening** with catch-all block to prevent DNS pointing attacks
- **fail2ban** configuration for SSH and bad bot protection
- **UFW firewall** configuration
- **Real-time monitoring** via n8n webhooks to Discord
- **Automated alerts** for SSH logins, IP bans, and DNS pointing attempts
- **Aggregated fail2ban summaries** to reduce Discord notification spam

## What is a DNS Pointing Attack?

Anyone can register a domain and point its DNS A record at any IP address - no permission required. If your nginx lacks a catch-all block, it will serve your content to unauthorized domains, effectively giving attackers free hosting on your infrastructure.

```
Attacker registers: malicious-domain.com
Attacker sets DNS:  malicious-domain.com -> YOUR_SERVER_IP
Result:             Your server serves content to their domain
```

This template prevents that.

---

## Quick Start

### 1. Clone the Repository

```bash
git clone https://github.com/YOUR_USERNAME/server-hardening-template.git
cd server-hardening-template
```

### 2. Configure Variables

Edit `config.env`:

```bash
cp config.env.example config.env
nano config.env
```

### 3. Run Setup Script

```bash
chmod +x scripts/rebuild-server.sh
sudo ./scripts/rebuild-server.sh
```

### 4. Set Up Monitoring (Optional)

1. Import `n8n/server-alerts-workflow.json` into n8n
2. Update Discord webhook URL in n8n
3. Run monitoring setup:

```bash
chmod +x scripts/setup-monitoring.sh
sudo ./scripts/setup-monitoring.sh
```

---

## File Structure

```
server-hardening-template/
├── README.md
├── config.env.example
├── scripts/
│   ├── rebuild-server.sh          # Main server setup
│   ├── setup-monitoring.sh        # Monitoring alerts setup
│   ├── daily-summary.sh           # Daily security report
│   └── fail2ban-summary.sh        # Aggregated ban alerts
├── nginx/
│   ├── nginx.conf                 # Main nginx config
│   └── site.conf.example          # Site config template
├── fail2ban/
│   ├── jail.d/
│   │   ├── sshd.conf
│   │   └── nginx-badbots.conf
│   ├── filter.d/
│   │   └── nginx-badbots.conf
│   └── action.d/
│       └── n8n-notify.conf
├── n8n/
│   └── server-alerts-workflow.json
└── docs/
    ├── INCIDENT-RESPONSE.md
    └── MAINTENANCE.md
```

---

## Configuration

### config.env.example

```bash
# Domain Configuration
DOMAIN="example.com"
WWW_DOMAIN="www.example.com"

# Server Configuration
SERVER_IP="YOUR_SERVER_IP"
SSH_PORT="22"

# Website Path
WEBSITE_ROOT="/var/www/html"
WEBSITE_DIST="/var/www/html/dist"

# SSL Configuration
SSL_EMAIL="your-email@example.com"

# Monitoring (Optional)
N8N_WEBHOOK_URL="https://your-n8n-instance.com/webhook/server-alert"
DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/YOUR_WEBHOOK_ID/YOUR_WEBHOOK_TOKEN"

# Swap Configuration
SWAP_SIZE="1G"
SWAPPINESS="60"
```

---

## Hardening Details

### 1. nginx Catch-All Block

Prevents DNS pointing attacks by dropping requests for unknown domains:

```nginx
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    server_name _;

    ssl_certificate /etc/nginx/ssl/dummy.crt;
    ssl_certificate_key /etc/nginx/ssl/dummy.key;

    access_log /var/log/nginx/unknown-hosts.log unknown_host;

    return 444;
}
```

### 2. Bad Bot Blocking

Blocks AI scrapers and malicious user agents:

```nginx
map $http_user_agent $bad_bot {
    default 0;
    "~*GPTBot" 1;
    "~*ChatGPT-User" 1;
    "~*ClaudeBot" 1;
    "~*CCBot" 1;
    "~*Bytespider" 1;
    "~*AhrefsBot" 1;
    "~*SemrushBot" 1;
    "~*python-requests" 1;
    "~*curl" 1;
    "~*wget" 1;
    "" 1;
}
```

### 3. Rate Limiting

```nginx
limit_req_zone $binary_remote_addr zone=slowbots:10m rate=5r/s;
limit_req zone=slowbots burst=20 nodelay;
```

### 4. fail2ban Jails

**SSH Protection:**
- 3 failed attempts = 1 hour ban

**Bad Bot Protection:**
- 1 bad request = 24 hour ban

### 5. UFW Firewall

Only ports 22, 80, and 443 open.

---

## Monitoring

### Alert Types

| Alert | Trigger | Frequency | Discord Color |
|-------|---------|-----------|---------------|
| SSH Login | Any SSH login | Instant | Blue |
| Fail2ban Summary | Aggregated bans | Every 30 min | Orange |
| DNS Pointing | Unknown host request | Every 5 min | Yellow |
| Daily Summary | Cron job | 9 AM UTC | Green |

### How Fail2ban Alerts Work

Instead of spamming Discord with every individual IP ban (which can be dozens per hour during brute force attacks), bans are:

1. **Logged** to `/var/log/fail2ban-bans.log` by `fail2ban-alert.sh`
2. **Aggregated** every 30 minutes by `fail2ban-summary.sh`
3. **Sent as ONE summary** to Discord with:
   - Total ban count
   - Breakdown by jail (sshd vs nginx-badbots)
   - Sample of banned IPs (up to 10)

This reduces notification noise while maintaining visibility.

### n8n Workflow

Import `n8n/server-alerts-workflow.json` and configure:

1. Update Discord webhook URL in each HTTP Request node
2. Activate the workflow
3. Copy the production webhook URL

The workflow handles these alert types:
- `ssh_login` - Instant SSH login alerts
- `fail2ban` - Legacy individual ban alerts (optional)
- `fail2ban_summary` - Aggregated ban summaries
- `unknown_host` - DNS pointing attempts
- `daily_summary` - Daily security report

### Server Scripts

After running `setup-monitoring.sh`, these scripts are installed:

| Script | Location | Purpose |
|--------|----------|---------|
| `n8n-alert.sh` | `/usr/local/bin/` | Base alert function |
| `ssh-login-alert.sh` | `/usr/local/bin/` | SSH login notifications |
| `fail2ban-alert.sh` | `/usr/local/bin/` | Logs bans to file for aggregation |
| `fail2ban-summary.sh` | `/usr/local/bin/` | Sends aggregated ban summaries |
| `unknown-host-monitor.sh` | `/usr/local/bin/` | DNS pointing detection |
| `daily-summary.sh` | `/usr/local/bin/` | Daily security report |

### Cron Jobs

```bash
# DNS pointing monitor (every 5 minutes)
*/5 * * * * /usr/local/bin/unknown-host-monitor.sh

# Fail2ban summary (every 30 minutes)
*/30 * * * * /usr/local/bin/fail2ban-summary.sh

# Daily summary (9 AM UTC)
0 9 * * * /usr/local/bin/daily-summary.sh
```

---

## Maintenance Commands

### nginx

```bash
nginx -t                              # Test config
systemctl reload nginx                # Reload
tail -f /var/log/nginx/access.log     # View access log
tail -f /var/log/nginx/unknown-hosts.log  # View DNS attempts
```

### fail2ban

```bash
fail2ban-client status                # All jails status
fail2ban-client status sshd           # SSH jail status
fail2ban-client set sshd banip IP     # Ban IP
fail2ban-client set sshd unbanip IP   # Unban IP
tail -f /var/log/fail2ban-bans.log    # View ban log (for aggregation)
```

### UFW

```bash
ufw status                            # Firewall status
ufw allow from IP                     # Allow IP
ufw deny from IP                      # Block IP
```

### Monitoring

```bash
/usr/local/bin/daily-summary.sh       # Run daily summary manually
/usr/local/bin/fail2ban-summary.sh    # Run fail2ban summary manually
cat /root/.n8n-webhook                # View webhook URL
cat /var/log/fail2ban-bans.log        # View pending bans
```

---

## Security Checklist

### Weekly

- [ ] Review fail2ban bans: `fail2ban-client status`
- [ ] Check unknown hosts: `tail -100 /var/log/nginx/unknown-hosts.log`
- [ ] Review auth log: `grep "Failed" /var/log/auth.log | tail -50`
- [ ] Check ban aggregation log: `tail -100 /var/log/fail2ban-bans.log`

### Monthly

- [ ] Update system: `apt update && apt upgrade`
- [ ] Review SSH keys: `cat ~/.ssh/authorized_keys`
- [ ] Check for new users: `cat /etc/passwd`
- [ ] Verify cron jobs: `crontab -l`
- [ ] Test backups

---

## Troubleshooting

### Website Not Loading

```bash
systemctl status nginx
nginx -t
curl -I -A "Mozilla/5.0 Chrome" https://YOUR_DOMAIN
```

### Not Receiving Alerts

```bash
cat /root/.n8n-webhook
# Test manually:
curl -X POST "$(cat /root/.n8n-webhook)" \
  -H "Content-Type: application/json" \
  -d '{"type":"test","message":"Test","ip":"127.0.0.1","timestamp":"2025-01-01T00:00:00Z"}'
```

### Fail2ban Summary Not Sending

```bash
# Check if bans are being logged
cat /var/log/fail2ban-bans.log

# Check last run timestamp
cat /tmp/fail2ban-summary-lastrun

# Run manually with debug
bash -x /usr/local/bin/fail2ban-summary.sh
```

### Locked Out of SSH

1. Use hosting provider's console (Linode LISH, etc.)
2. Temporarily enable password auth
3. Fix SSH key
4. Disable password auth again

---

## Contributing

1. Fork the repository
2. Create a feature branch
3. Submit a pull request

---

## License

MIT License - See LICENSE file

---

## Acknowledgments

Developed after experiencing a real DNS pointing attack. Learn more about the incident and response in [docs/INCIDENT-RESPONSE.md](docs/INCIDENT-RESPONSE.md).
