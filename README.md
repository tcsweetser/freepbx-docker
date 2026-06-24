## Introduction

This is MVP [Docker Compose](https://docs.docker.com/compose/) application for having [FreePBX](https://www.freepbx.org) - A Voice over IP manager for [Asterisk](https://www.asterisk.org), running in containers.

Upon starting this multi-container application, it will give you a turnkey PBX system for SIP calling.

* FreePBX 17.0.21
* PHP 8.2.29
* Asterisk 21.10.2
* MariaDB 10.11.14
* Fail2ban pre-configured with restrictive enforcement rules
* Email notifications
* Logrotate configured also for Asterisk and Freepbx
* Supports data persistence
* Base image Debian [debian:bookworm-slim](https://hub.docker.com/_/debian/)
* Apache 2.4.65
* NodeJS v18.20.4
* DAHDI channel not supported

### Networking model
FreePBX runs with Docker **host networking**, so it binds directly to the host's
LAN interfaces on both IPv4 and IPv6 (dual-stack). No Docker port-mapping or
iptables DNAT is used.

| Port              | Protocol | Binding |
| ----------------- | -------- | --------------- |
| `80/tcp`          | HTTP     | dual-stack (IPv4 + IPv6) |
| `443/tcp`         | HTTPS    | dual-stack (IPv4 + IPv6) |
| `5060/udp`        | PJSIP    | dual-stack (IPv4 + IPv6) |
| `56600-56800/udp` | RTP      | dual-stack (IPv4 + IPv6) |

Because RTP binds straight to the host, the large UDP range needs no special
Docker handling. External IPv4 SIP-trunk reachability is provided by the site
router (see [Mikrotik RB5009 firewall fragments](docs/mikrotik-rb5009-firewall.md)).

The MariaDB container stays on an internal Docker bridge and is published only to
`127.0.0.1:3306` — it is never exposed on the LAN.

### Host requirements
- Host networking enabled (Linux). FreePBX binds 80/443/5060 + RTP directly on
  the host, dual-stack. No host iptables/DNAT rules are required by this project.
- A dual-stack LAN (IPv4 + IPv6) if you want IPv6 phone registration.
- Customize Fail2ban preferences by editing the file `fail2ban/jail.local`. Currently it bans 2 consecutive failed SIP registration attempts within 30 seconds for 1 week.

- Make sure you have a valid DNS server for Docker containers by adding the following to `/etc/docker/daemon.json` (restart Docker after saving the file):
  ```json
  {
    "dns": ["1.1.1.1"]
  }
  ```

## Usage
1. Create required passwords:
```bash
# for MySQL root user
printf "your-mysql-root-password" > mysql_root_password.txt
printf "yourstrongmysqlfreepbxuserpassword" > freepbxuser_password.txt

# for Postfix
# run this command even if you don't need email notifications
printf "[smtp-server-fqdn]:port your-email@gmail.com:your-app-password" > sasl_passwd.txt

# Set proper file permissions
chmod 600 mysql_root_password.txt freepbxuser_password.txt sasl_passwd.txt
```

2. To complete postfix configuration, set the `relayhost` in [postfix/main.cf](source/postfix/main.cf) to match your SMTP server defined in `sasl_passwd.txt`. 

3. OPTION A: build the image from scratch:
```bash
cd source && sudo docker build -t your-image-name:your-tag .
```
Then edit the value of `services.freepbx.image` in the [docker-compose.yaml](docker-compose.yaml) by setting the proper image version and tag.

3. OPTION B: if you want to use the pre-built image on Docker Hub, jump to the next step directly

4. Build + run the Compose project (host networking; no iptables step):
```bash
sudo bash run.sh

# Install Freepbx
sudo bash run.sh --install-freepbx

# Optional, clean up containers, network and volumes
sudo bash run.sh --clean-all
```

5. TLS support using Let's Encrypt DNS challenge
```bash
# Make sure to have both 80 and 443 TCP ports allowed by the firewall and a valid DNS record A
sudo docker compose exec -it freepbx certbot --apache -d your.domain.com --email your-email@email.com --agree-tos --redirect -n
```

Login to the web server's admin URL and start configuring the system!

## Dual-stack SIP configuration (FreePBX)

After first login, configure PJSIP so phones can register over IPv6 while the
IPv4 trunk advertises the correct public address:

1. **Add an IPv6 SIP transport.** Keep the default IPv4 transport
   (`0.0.0.0:5060`) and add a second UDP transport bound to `[::]:5060`
   (Settings → Asterisk SIP Settings → PJSIP). Phones then register over either
   family.
2. **Set IPv4 trunk NAT.** On the IPv4 transport / trunk set
   `external_signaling_address` and `external_media_address` to the Mikrotik's
   **public IPv4**, and `local_net` to your LAN ranges — both the IPv4 subnet and
   the IPv6 ULA `fcd1::/64`. The port-forwarded IPv4 trunk then puts the public
   address in SDP, while internal IPv6 phones receive the native LAN address.
   The upstream trunk peer is `103.51.112.38`.
3. **Set the RTP port range** (Settings → Asterisk SIP Settings → RTP) to
   **`56600`–`56800`** so media matches the open range forwarded by the router.
   A mismatch here silently breaks audio.
4. **Verify dual-stack listeners** on the host:
   ```bash
   sudo ss -tlnp 'sport = :80'   # expect *:80 and [::]:80
   sudo ss -ulnp 'sport = :5060' # expect 0.0.0.0:5060 and [::]:5060
   ```

Router-side firewall rules for the trunk and IPv6 phones are in
[docs/mikrotik-rb5009-firewall.md](docs/mikrotik-rb5009-firewall.md).

**If you find this project useful or inspiring**

<a href="https://www.buymeacoffee.com/emilianospada">
  <img src="https://i.postimg.cc/W1qS7R25/bmc-button-counter.jpg" alt="Buy me a coffee" width="320">
</a>

