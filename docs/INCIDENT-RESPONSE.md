# DNS Pointing Attack - Incident Response Case Study

## Executive Summary

This document details the discovery, analysis, and remediation of a DNS pointing attack against a web server. The attack involved external actors registering domains and pointing their DNS A records at our server IP without authorization, causing our server to appear as the source of malicious activity.

---

## Timeline

| Date | Event |
|------|-------|
| Day 0 | Received abuse notice from hosting provider |
| Day 0 | Initial investigation revealed DNS pointing attack |
| Day 0 | Implemented temporary mitigations |
| Day 1 | Full forensic analysis completed |
| Day 1 | Server rebuilt from clean image with new IP |
| Day 1 | Hardening measures implemented |
| Day 2 | Monitoring and alerting deployed |

---

## Attack Description

### What is a DNS Pointing Attack?

DNS (Domain Name System) allows anyone to point a domain at any IP address - no ownership verification required. In this attack:

1. Attacker registers domain (e.g., `malicious-domain.com`)
2. Attacker points DNS A record at victim's IP
3. Visitors to attacker's domain receive content from victim's server
4. When bots scan attacker's domain for vulnerabilities, victim's IP appears in logs as the scanner

### Impact

- Server falsely accused of malicious scanning activity
- Received Terms of Service violation notice
- Potential reputation damage to IP address
- Resources consumed by malicious traffic

---

## Root Cause Analysis

The vulnerability existed because nginx was configured without a default catch-all server block:

**Vulnerable Configuration:**
```nginx
server {
    listen 80;
    server_name example.com www.example.com;
    # ... 
}
```

This configuration responds to ANY request, regardless of the Host header, allowing any domain pointed at the IP to receive content.

**Secure Configuration:**
```nginx
# Catch-all block FIRST
server {
    listen 80 default_server;
    server_name _;
    return 444;
}

# Legitimate domain block SECOND
server {
    listen 80;
    server_name example.com www.example.com;
    # ...
}
```

---

## Forensic Analysis

### Server Integrity Check

| Check | Result |
|-------|--------|
| `/var/log/auth.log` | Only authorized logins |
| `/tmp` directory | No malicious files |
| Running processes | Normal services only |
| SSH authorized_keys | Unmodified |
| Crontab | Clean |
| rkhunter scan | 0 rootkits found |
| ClamAV scan | No malware detected |

**Conclusion:** Server was NOT compromised. Attack was purely external DNS abuse.

### Log Analysis

- Thousands of requests logged for unauthorized domains
- WordPress vulnerability scanning patterns observed
- Multiple source IPs associated with known scanning networks

---

## MITRE ATT&CK Mapping

| Technique ID | Name | Description |
|-------------|------|-------------|
| T1583.001 | Acquire Infrastructure: Domains | Attacker registered domains |
| T1584.004 | Compromise Infrastructure: Server | Used victim as unwitting proxy |
| T1090 | Proxy | Victim server proxied attacker content |

---

## Remediation Steps

### Immediate (Day 0)

1. Added nginx catch-all server block
2. Configured fail2ban for bad bot blocking
3. Filed abuse reports with domain registrar

### Complete (Day 1)

1. Backed up all critical data
2. Rebuilt server from clean OS image
3. Obtained new IP address
4. Implemented comprehensive hardening
5. Deployed monitoring and alerting

---

## Indicators of Compromise (IOCs)

### Malicious Domains

```
urjaihaircompany.com
glambygemia.com
wealthplannerspro.com
```

### Malicious User Agents

```
GPTBot
ClaudeBot
AhrefsBot
SemrushBot
python-requests
CensysInspect
```

---

## Lessons Learned

1. **nginx catch-all block is essential** - Without it, any domain can use your server
2. **DNS requires no authentication** - Anyone can point any domain at any IP
3. **Abuse reports blame the IP** - Victim servers get falsely accused
4. **Host header validation is critical** - Server-side validation is the only defense
5. **Monitoring enables rapid response** - Real-time alerts caught new attacks immediately

---

## Recommendations

### Technical Controls

- [ ] Implement nginx catch-all default server block
- [ ] Enable fail2ban with custom bad bot filter
- [ ] Configure UFW firewall with minimal open ports
- [ ] Set up real-time alerting for suspicious activity
- [ ] Regularly review access logs

### Process Controls

- [ ] Document all legitimate domains
- [ ] Establish incident response procedures
- [ ] Regular security audits
- [ ] Log retention policy

---

## References

- [nginx Server Block Selection](https://nginx.org/en/docs/http/request_processing.html)
- [fail2ban Documentation](https://www.fail2ban.org/)
- [MITRE ATT&CK Framework](https://attack.mitre.org/)
