# Host-Networked Dual-Stack FreePBX Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the FreePBX container to host networking so internal phones reach it over native dual-stack (IPv4 + IPv6) on the LAN, keep the IPv4 SIP trunk working via Mikrotik port-forward, and ship operator docs for the router firewall.

**Architecture:** `freepbx` switches to `network_mode: host` (binds 80/443/5060 directly on host interfaces, dual-stack). `db` stays on the Docker bridge but publishes `127.0.0.1:3306` only. `run.sh` drops all iptables/DNAT logic (host networking makes it obsolete) and becomes a thin compose wrapper. README and a new Mikrotik RB5009 doc capture the Asterisk-level and router-level configuration.

**Tech Stack:** Docker Compose, MariaDB 10.11, FreePBX 17 / Asterisk 21 (PJSIP), Apache 2.4, RouterOS v7.

## Global Constraints

- External SIP trunk stays IPv4-only; reached via Mikrotik IPv4 port-forward. Do NOT add IPv6 trunk config.
- SIP trunk source IP is **`103.51.112.38`**; router forwards `5060/udp` ONLY from that source.
- `db` MUST publish only to `127.0.0.1` — never `0.0.0.0`. The `127.0.0.1:` prefix is load-bearing.
- 80/tcp, 443/tcp, 5060/udp MUST bind dual-stack (both IPv4 and IPv6).
- RTP media port range: **`56600-56800/udp`**, forwarded **open** (no source restriction). Asterisk's RTP range must be set to match.
- Internal phones use IPv6 ULA **`fcd1::/64`**; FreePBX provisioning address is **`fcd1::beef`** (the host LAN interface must carry it).
- FQDN is **`pbx.ieisi.org`** with a **public AAAA → `fcd1::beef`** (added by hand at Cloudflare). First cert via Let's Encrypt **manual DNS-01** (bootstrap), issued inside the freepbx container into the `etc_data` volume. **Steady-state renewal is automated on a 45-day rotation** via `certbot --dns-cloudflare` + a daily host systemd timer (Task 6). No inbound ports.
- Provisioning URL is **`https://pbx.ieisi.org/`** (primary, DHCP-advertised); **`http://[fcd1::beef]/`** is a documented manual fallback only.
- Yealink phones; DHCP advertises **both** option 66 (IPv4) and option 59 (DHCPv6), each pointing to `https://pbx.ieisi.org/`.
- `init.sql` and `my.cnf` MUST NOT change — the existing `freepbxuser'@'%'` grant already covers TCP from `127.0.0.1`.
- No code is executed against the live router by this repo; RouterOS fragments are documentation only.
- Conventional Commits; one commit per task.

## File Structure

- `docker-compose.yaml` — modify: `freepbx` → host net, `db` → bridge + localhost-published port.
- `run.sh` — rewrite: thin wrapper (install / clean / up), drop iptables.
- `README.md` — modify: replace ports/iptables narrative, update usage, add Asterisk dual-stack + trunk-NAT section, link router doc.
- `docs/mikrotik-rb5009-firewall.md` — create: RouterOS v7 firewall + DHCP-provisioning fragments.

---

### Task 1: Switch docker-compose to host-networked FreePBX + loopback DB

**Files:**
- Modify: `docker-compose.yaml`

**Interfaces:**
- Produces: `freepbx` service on host network (no Docker-managed ports); `db` reachable at `127.0.0.1:3306` from the host. Consumed by Task 2 (`--dbhost=127.0.0.1`).

- [ ] **Step 1: Edit the `db` service network/ports**

In `docker-compose.yaml`, replace the `db` service's `networks:` block:

```yaml
    networks:
      defaultnet:
        ipv4_address: 172.18.0.10
```

with a bridge attachment plus a loopback-only published port:

```yaml
    networks:
      - defaultnet
    ports:
      - "127.0.0.1:3306:3306"
```

- [ ] **Step 2: Switch the `freepbx` service to host networking**

Replace the `freepbx` service's `networks:` and `ports:` blocks:

```yaml
    networks:
      defaultnet:
        ipv4_address: 172.18.0.20
    ports:
      - "80:80/tcp"
      - "443:443/tcp"
      - "5060:5060/udp"
```

with a single line:

```yaml
    network_mode: host
```

(Leave `volumes:`, `secrets:`, and `depends_on:` for `freepbx` unchanged.)

- [ ] **Step 3: Verify the compose file parses**

Run: `docker compose config >/dev/null && echo OK`
Expected: prints `OK` with no errors. (If `docker compose` is unavailable in the environment, run `python3 -c "import yaml,sys; yaml.safe_load(open('docker-compose.yaml')); print('OK')"` instead.)

- [ ] **Step 4: Confirm the host-net / port constraints hold**

Run: `grep -n "network_mode: host" docker-compose.yaml && grep -n "127.0.0.1:3306:3306" docker-compose.yaml && ! grep -n "172.18.0.20" docker-compose.yaml && echo OK`
Expected: shows the two matches, no `172.18.0.20`, prints `OK`.

- [ ] **Step 5: Commit**

```bash
git add docker-compose.yaml
git commit -m "feat: host-network freepbx, publish db to loopback only

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Reduce run.sh to a thin wrapper

**Files:**
- Modify: `run.sh` (full rewrite)

**Interfaces:**
- Consumes: `db` at `127.0.0.1:3306` from Task 1.
- Produces: `run.sh` supporting `--install-freepbx`, `--clean-all`, and bare invocation (`docker compose up -d`). No iptables side effects.

- [ ] **Step 1: Replace the entire `run.sh` body**

Overwrite `run.sh` with:

```bash
#!/usr/bin/env bash
set -euo pipefail

# FreePBX runs on host networking, so RTP/SIP bind directly to the host
# interfaces (dual-stack). No iptables DNAT is required here anymore;
# external IPv4 trunk reachability is handled on the Mikrotik RB5009
# (see docs/mikrotik-rb5009-firewall.md).

# INSTALL FREEPBX
if [[ "$*" == *"--install-freepbx"* ]]; then
    sudo docker compose exec -it -w /usr/local/src/freepbx freepbx \
        php install -n --dbuser=freepbxuser \
        --dbpass="$(cat freepbxuser_password.txt)" --dbhost=127.0.0.1

# CLEAN
elif [[ "$*" == *"--clean-all"* ]]; then
    read -r -p "Are you sure you want to clean up everything? Data will be lost. (yes/no)? " confirmation
    if [[ "$confirmation" != "yes" ]]; then
        echo "Cleanup aborted."
        exit 0
    fi
    sudo docker container stop freepbx-docker-db-1 && sudo docker container rm freepbx-docker-db-1
    sudo docker container stop freepbx-docker-freepbx-1 && sudo docker container rm freepbx-docker-freepbx-1
    sudo docker container stop fail2ban && sudo docker container rm fail2ban
    sudo docker volume rm freepbx-docker_var_data
    sudo docker volume rm freepbx-docker_etc_data
    sudo docker volume rm freepbx-docker_mysql_data
    sudo docker network rm freepbx-docker_defaultnet

# START
else
    sudo docker compose up -d && {
        printf "Waiting for database readiness"
        for _ in $(seq 1 10); do printf "."; sleep 1; done
        echo " done"
    }
fi
```

- [ ] **Step 2: Verify shell syntax**

Run: `bash -n run.sh && echo OK`
Expected: prints `OK`, no syntax errors.

- [ ] **Step 3: Confirm the iptables logic is gone and dbhost is loopback**

Run: `! grep -qiE "iptables|DNAT|DOCKER-USER|get_default_iface|--rtp" run.sh && grep -q "dbhost=127.0.0.1" run.sh && echo OK`
Expected: prints `OK`.

- [ ] **Step 4: Commit**

```bash
git add run.sh
git commit -m "refactor: reduce run.sh to thin compose wrapper, drop iptables DNAT

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Add the Mikrotik RB5009 firewall + DHCP doc

**Files:**
- Create: `docs/mikrotik-rb5009-firewall.md`

**Interfaces:**
- Produces: a doc path linked from README in Task 4 and Task 5. Uses the
  deployment's concrete values (trunk `103.51.112.38`, RTP `56600-56800`,
  ULA `fcd1::/64`, PBX `fcd1::beef`).

- [ ] **Step 1: Create `docs/mikrotik-rb5009-firewall.md`**

Write the file with this content:

````markdown
# Mikrotik RB5009 (RouterOS v7) firewall + DHCP fragments

Copy-paste fragments for exposing the host-networked FreePBX. The IPv4 SIP trunk
is port-forwarded (DNAT) from the WAN; internal phones reach the PBX over IPv6
(ULA) through the `forward` chain; DHCP hands phones the provisioning URL.
Verify rule ordering (RouterOS evaluates top-down; firewall rules must sit
**above** your default `drop` rules).

## Values used here

| Item | Value |
| --- | --- |
| SIP trunk source IPv4 | `103.51.112.38` |
| RTP media range (open) | `56600-56800/udp` |
| Internal phone ULA prefix | `fcd1::/64` |
| FreePBX provisioning ULA | `fcd1::beef` |
| Provisioning URL | `http://[fcd1::beef]/` |
| `<PBX_LAN_IPV4>` (substitute) | PBX host LAN IPv4, e.g. `192.168.88.10` |
| WAN / LAN | your interface-list names |

> Note: `fcd1::/64` is in the `fc00::/8` half of ULA space (the strictly
> "correct" locally-assigned half is `fd00::/8`). It routes fine on a private
> LAN; this is intentional for this deployment.

## 1. IPv4 — DNAT the trunk to the PBX

The trunk signalling is locked to the provider source; the RTP range is left
open for unknown media gateways.

```routeros
/ip firewall nat
add chain=dstnat in-interface-list=WAN protocol=udp dst-port=5060 \
    src-address=103.51.112.38 action=dst-nat \
    to-addresses=<PBX_LAN_IPV4> to-ports=5060 \
    comment="FreePBX: SIP trunk signalling (provider only)"
add chain=dstnat in-interface-list=WAN protocol=udp dst-port=56600-56800 \
    action=dst-nat to-addresses=<PBX_LAN_IPV4> \
    comment="FreePBX: RTP media (open, unknown media gateways)"
```

## 2. IPv4 — allow the forwarded traffic

```routeros
/ip firewall filter
add chain=forward connection-state=established,related action=accept \
    comment="FreePBX: established/related"
add chain=forward connection-nat-state=dstnat protocol=udp dst-port=5060 \
    src-address=103.51.112.38 dst-address=<PBX_LAN_IPV4> action=accept \
    comment="FreePBX: SIP trunk in (provider only)"
add chain=forward connection-nat-state=dstnat protocol=udp dst-port=56600-56800 \
    dst-address=<PBX_LAN_IPV4> action=accept comment="FreePBX: RTP in (open)"
```

## 3. IPv6 — internal phones to the PBX, block WAN inbound

```routeros
/ipv6 firewall address-list
add list=pbx-host address=fcd1::beef comment="FreePBX host (ULA)"
add list=lan-phones address=fcd1::/64 comment="Internal phones (ULA)"

/ipv6 firewall filter
add chain=forward connection-state=established,related action=accept \
    comment="FreePBX v6: established/related"
add chain=forward src-address-list=lan-phones dst-address-list=pbx-host \
    protocol=udp dst-port=5060 action=accept comment="FreePBX v6: SIP from phones"
add chain=forward src-address-list=lan-phones dst-address-list=pbx-host \
    protocol=udp dst-port=56600-56800 action=accept comment="FreePBX v6: RTP from phones"
add chain=forward src-address-list=lan-phones dst-address-list=pbx-host \
    protocol=tcp dst-port=80,443 action=accept comment="FreePBX v6: web/prov from phones"
add chain=forward in-interface-list=WAN dst-address-list=pbx-host action=drop \
    comment="FreePBX v6: drop unsolicited WAN inbound"
```

## 4. DHCP — advertise the provisioning URL (Yealink)

Hand the provisioning URL to phones over **both** families so a Yealink phone
provisions regardless of which it uses. Option 66 (IPv4) and option 59 (DHCPv6)
both point at the FQDN `https://pbx.ieisi.org/` (which resolves to `fcd1::beef`).

```routeros
# IPv4 DHCP option 66 (provisioning server URL).
/ip dhcp-server option
add code=66 name=prov-url-v4 value="'https://pbx.ieisi.org/'"
/ip dhcp-server network
# attach the option to your phone LAN network entry, e.g.:
# set [find address=192.168.88.0/24] dhcp-option=prov-url-v4

# DHCPv6 option 59 (OPT_BOOTFILE_URL) with the same URL.
/ipv6 dhcp-server option
add code=59 name=prov-url-v6 value="'https://pbx.ieisi.org/'"
/ipv6 dhcp-server
# attach prov-url-v6 to the DHCPv6 server serving fcd1::/64, e.g.:
# set [find name=dhcpv6-phones] dhcp-option=prov-url-v6
```

> The exact per-network attachment lines depend on your existing DHCP server
> names; the `# set ...` comments show the pattern. Yealink reads option 66
> directly and option 59 when provisioning over DHCPv6. The `http://[fcd1::beef]/`
> literal is a manual phone-side fallback (a TLS cert can't validate an IP
> literal), so it is NOT advertised by DHCP.

## DNS prerequisite

`pbx.ieisi.org` must publish a **public AAAA → `fcd1::beef`** (at your DNS
registrar/provider). The ULA is non-routable from the internet, so external
clients get an unreachable address while internal phones resolve it and reach the
PBX on-LAN. No split-horizon DNS is required. The TLS cert for `pbx.ieisi.org` is
issued via Let's Encrypt **DNS-01** (TXT record at `_acme-challenge.pbx.ieisi.org`)
— no inbound 80/443 from WAN is needed.

## Notes

- The IPv6 trunk is intentionally NOT configured; the trunk stays IPv4 via DNAT.
- The host's LAN interface must carry `fcd1::beef` so FreePBX (host networking)
  answers HTTPS provisioning on the ULA.
- After adding rules, confirm placement with `/ip firewall filter print` and
  `/ipv6 firewall filter print` so they precede any default drop.
- The PBX is also firewalled by fail2ban (host-networked) on top of these rules.
````

- [ ] **Step 2: Verify the doc renders and has the required sections**

Run: `grep -cE "^/ip firewall nat|^/ip firewall filter|^/ipv6 firewall filter|^/ip dhcp-server option|^/ipv6 dhcp-server option" docs/mikrotik-rb5009-firewall.md && grep -q "103.51.112.38" docs/mikrotik-rb5009-firewall.md && grep -q "56600-56800" docs/mikrotik-rb5009-firewall.md && grep -q "fcd1::beef" docs/mikrotik-rb5009-firewall.md && grep -q "pbx.ieisi.org" docs/mikrotik-rb5009-firewall.md && echo OK`
Expected: prints `5` then `OK` (all five RouterOS blocks present, concrete values embedded).

- [ ] **Step 3: Commit**

```bash
git add docs/mikrotik-rb5009-firewall.md
git commit -m "docs: add Mikrotik RB5009 RouterOS v7 firewall fragments

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Rewrite README for host networking + dual-stack + trunk NAT

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: `docs/mikrotik-rb5009-firewall.md` (Task 3) for the link.

- [ ] **Step 1: Replace the "Ports" + RTP narrative**

In `README.md`, replace the block from `### Ports` through the end of the
`So [run.sh](run.sh) will take care of iptables configuration...` paragraph with:

```markdown
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
```

- [ ] **Step 2: Replace the "Host requirements" iptables bullets**

Replace the `### Host requirements` section's first three bullets (the `ip`,
`iptables`, `awk` requirement; the "iptables rules inside the Docker chains"
bullet; and the `iptables-persistent` code block) with:

```markdown
- Host networking enabled (Linux). FreePBX binds 80/443/5060 + RTP directly on
  the host, dual-stack. No host iptables/DNAT rules are required by this project.
- A dual-stack LAN (IPv4 + IPv6) if you want IPv6 phone registration.
```

- [ ] **Step 3: Update the Usage start/run step**

Replace usage step 4 (`Configure RTP ports on the host and build + run...` and
its code block, including the `--rtp` note) with:

```markdown
4. Build + run the Compose project (host networking; no iptables step):
```bash
sudo bash run.sh

# Install Freepbx
sudo bash run.sh --install-freepbx

# Optional, clean up containers, network and volumes
sudo bash run.sh --clean-all
```
```

- [ ] **Step 4: Add the dual-stack Asterisk + trunk-NAT section**

Immediately after the Usage section's final "Login to the web server's admin
URL..." line, add:

```markdown
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
```

- [ ] **Step 5: Verify the README links and sections exist**

Run: `grep -q "Networking model" README.md && grep -q "Dual-stack SIP configuration" README.md && grep -q "docs/mikrotik-rb5009-firewall.md" README.md && ! grep -qi "run.sh will take care of iptables" README.md && echo OK`
Expected: prints `OK`.

- [ ] **Step 6: Commit**

```bash
git add README.md
git commit -m "docs: rewrite README for host networking and dual-stack SIP

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: Document FQDN, DNS-01 TLS, and Yealink auto-provisioning

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: `docs/mikrotik-rb5009-firewall.md` DHCP/DNS section (Task 3) for the link.

- [ ] **Step 1: Replace the README TLS step with manual DNS-01**

In `README.md`, replace the existing TLS step (the `5. TLS support using Let's
Encrypt DNS challenge` heading and its `certbot --apache` code block) with:

```markdown
5. TLS certificate for `pbx.ieisi.org` (Let's Encrypt, manual DNS-01)

The PBX is reachable only on the internal ULA (`fcd1::beef`), so it has no
public-facing port — issue the cert with the **DNS-01** challenge (no inbound
80/443 required). Issue from inside the container; the cert persists in the
`etc_data` volume under `/etc/letsencrypt`:
```bash
sudo docker compose exec -it freepbx \
  certbot certonly --manual --preferred-challenges dns \
  -d pbx.ieisi.org --email your-email@email.com --agree-tos

# certbot prints a TXT name/value and PAUSES. In the Cloudflare dashboard add:
#   Type=TXT  Name=_acme-challenge.pbx.ieisi.org  Value=<printed value>
# Wait for it to propagate, then press Enter to let certbot validate and issue.

# Point Apache's vhost (ServerName pbx.ieisi.org) at:
#   /etc/letsencrypt/live/pbx.ieisi.org/fullchain.pem
#   /etc/letsencrypt/live/pbx.ieisi.org/privkey.pem
# then reload Apache.
```
This first cert is a **bootstrap**. Manual DNS-01 cannot be auto-renewed, so the
next section switches renewal to automated 45-day rotation via a Cloudflare token.
```

- [ ] **Step 2: Add the provisioning section to README**

Immediately after the "Dual-stack SIP configuration (FreePBX)" section added in
Task 4, add:

```markdown
## Phone auto-provisioning (Yealink, IPv6 ULA + FQDN)

Yealink phones fetch their config from FreePBX over the internal IPv6 ULA, using
the FQDN so TLS validates. The provisioning URL is advertised by the router's
DHCP and served by FreePBX on the host's ULA address.

**Prerequisites:**

1. **Public DNS.** `pbx.ieisi.org` publishes a **public AAAA → `fcd1::beef`**.
   The ULA is unreachable from the internet; internal phones resolve it and reach
   the PBX on-LAN (no split-horizon needed).
2. **Host ULA address.** The host's LAN interface must carry `fcd1::beef` (static
   or via router RA/DHCPv6). Because FreePBX uses host networking, this is the
   address that answers provisioning. Verify:
   ```bash
   ip -6 addr show scope global | grep -i 'fcd1::beef'
   ```
3. **FreePBX provisioning server.** Configure Endpoint Manager so the per-MAC
   Yealink config is served from `https://pbx.ieisi.org/` (cert from step 5).
4. **DHCP advertises the URL.** The Mikrotik hands out `https://pbx.ieisi.org/`
   via **both** IPv4 DHCP option 66 and DHCPv6 option 59 — see
   [docs/mikrotik-rb5009-firewall.md](docs/mikrotik-rb5009-firewall.md) section 4.
   Yealink reads option 66 directly and option 59 when provisioning over DHCPv6.

**Fallback:** for phones/firmware that cannot validate the cert, set the
provisioning URL manually to `http://[fcd1::beef]/` (no TLS).

**Phone-side check:** on the Yealink web UI, Settings → Auto Provision shows the
server URL `https://pbx.ieisi.org/`; a manual "Autoprovision Now" pulls the
config without a cert error.
```

- [ ] **Step 3: Verify the provisioning + TLS sections exist**

Run: `grep -q "Phone auto-provisioning" README.md && grep -q "pbx.ieisi.org" README.md && grep -q "DNS-01" README.md && grep -q "option 66" README.md && grep -q "option 59" README.md && grep -q "fcd1::beef" README.md && echo OK`
Expected: prints `OK`.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: document FQDN, DNS-01 TLS, and Yealink HTTPS provisioning

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: Automate cert rotation (Cloudflare DNS-01, 45-day)

Adds unattended renewal. The first cert may still be bootstrapped via the manual
TXT (Task 5); this task re-issues once with `--dns-cloudflare` to switch the
renewal authenticator, then schedules a daily renew check that rotates the cert
at the 45-day mark.

**Files:**
- Modify: `source/Dockerfile:34` (add the Cloudflare DNS plugin)
- Modify: `docker-compose.yaml` (add the `cloudflare_dns_token` secret)
- Modify: `.gitignore` (ignore the credentials file)
- Create: `renew-cert.sh` (host renewal wrapper)
- Create: `docs/systemd/freepbx-cert-renew.service`
- Create: `docs/systemd/freepbx-cert-renew.timer`
- Modify: `README.md` (automation section)

**Interfaces:**
- Consumes: the cert + Apache vhost from Task 5; the freepbx service from Task 1.
- Produces: a Docker secret `cloudflare_dns_token` mounted at
  `/run/secrets/cloudflare_dns_token`; a host script `renew-cert.sh`.

- [ ] **Step 1: Bake the Cloudflare DNS plugin into the image**

In `source/Dockerfile`, change line 34 from:

```dockerfile
  certbot python3-certbot-apache logrotate
```

to:

```dockerfile
  certbot python3-certbot-apache python3-certbot-dns-cloudflare logrotate
```

- [ ] **Step 2: Add the Cloudflare token as a Docker secret**

In `docker-compose.yaml`, add to the top-level `secrets:` block:

```yaml
  cloudflare_dns_token:
    file: cloudflare_dns_credentials.ini
```

and attach it to the `freepbx` service's `secrets:` list (mode `0400` so certbot
does not warn about world-readable credentials):

```yaml
    secrets:
      - postfix_sasl_passwd
      - source: cloudflare_dns_token
        target: cloudflare_dns_token
        mode: 0400
```

- [ ] **Step 3: Gitignore the credentials file**

Append to `.gitignore` (the existing `*.txt` rule does not cover `.ini`, and
other `.ini` files in `source/odbc/` are tracked, so ignore it explicitly):

```gitignore
# Cloudflare DNS-01 API token (certbot)
cloudflare_dns_credentials.ini
```

- [ ] **Step 4: Verify compose still parses and the secret is wired**

Run: `docker compose config >/dev/null && grep -q "cloudflare_dns_token" docker-compose.yaml && grep -q "cloudflare_dns_credentials.ini" .gitignore && echo OK`
Expected: prints `OK`.

- [ ] **Step 5: Create the host renewal wrapper `renew-cert.sh`**

Create `renew-cert.sh` at the repo root:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Daily Let's Encrypt renewal check for pbx.ieisi.org (Cloudflare DNS-01).
# certbot renews only when inside the renew_before_expiry window (45 days),
# then gracefully reloads Apache inside the freepbx container.
cd "$(dirname "$(readlink -f "$0")")"

sudo docker compose exec -T freepbx \
    certbot renew --quiet \
    --deploy-hook "apachectl -k graceful"
```

Then: `chmod +x renew-cert.sh`.

- [ ] **Step 6: Verify the wrapper's syntax**

Run: `bash -n renew-cert.sh && echo OK`
Expected: prints `OK`.

- [ ] **Step 7: Create the systemd units**

Create `docs/systemd/freepbx-cert-renew.service`:

```ini
[Unit]
Description=FreePBX Let's Encrypt renewal (Cloudflare DNS-01)
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/home/terry/freepbx-docker/renew-cert.sh
```

Create `docs/systemd/freepbx-cert-renew.timer`:

```ini
[Unit]
Description=Daily FreePBX cert renewal check

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
```

- [ ] **Step 8: Add the README automation section**

After the TLS step (Usage step 5), add:

```markdown
### Automated certificate rotation (45-day, Cloudflare DNS-01)

The manual cert above does not auto-renew. To rotate unattended:

1. **Create a scoped Cloudflare API token** (`Zone:DNS:Edit` + `Zone:Read` on
   `ieisi.org`) and write it to `cloudflare_dns_credentials.ini` (gitignored):
   ```ini
   dns_cloudflare_api_token = <your-token>
   ```
   Rebuild/recreate so the `cloudflare_dns_token` secret is mounted, and ensure
   the image includes the DNS plugin (`python3-certbot-dns-cloudflare`).

2. **Re-issue once with the DNS plugin** to switch the renewal authenticator from
   `manual` to `dns-cloudflare`:
   ```bash
   sudo docker compose exec -it freepbx \
     certbot certonly --dns-cloudflare \
     --dns-cloudflare-credentials /run/secrets/cloudflare_dns_token \
     -d pbx.ieisi.org --email your-email@email.com --agree-tos -n
   ```

3. **Set the 45-day rotation window** by adding this line to
   `/etc/letsencrypt/renewal/pbx.ieisi.org.conf` inside the container:
   ```
   renew_before_expiry = 45 days
   ```
   On a 90-day cert, certbot then renews at 45 days remaining → a 45-day rotation.

4. **Schedule the daily renew check** on the host. Either the systemd timer:
   ```bash
   sudo cp docs/systemd/freepbx-cert-renew.{service,timer} /etc/systemd/system/
   sudo systemctl daemon-reload
   sudo systemctl enable --now freepbx-cert-renew.timer
   systemctl list-timers freepbx-cert-renew.timer
   ```
   …or a cron alternative:
   ```cron
   17 3 * * * /home/terry/freepbx-docker/renew-cert.sh >> /var/log/freepbx-cert-renew.log 2>&1
   ```
   `renew-cert.sh` runs `certbot renew` in the container and gracefully reloads
   Apache only when a renewal actually happens.
```

- [ ] **Step 9: Verify the README + units exist**

Run: `grep -q "Automated certificate rotation" README.md && grep -q "renew_before_expiry = 45 days" README.md && test -f docs/systemd/freepbx-cert-renew.timer && grep -q "python3-certbot-dns-cloudflare" source/Dockerfile && echo OK`
Expected: prints `OK`.

- [ ] **Step 10: Commit**

```bash
git add source/Dockerfile docker-compose.yaml .gitignore renew-cert.sh docs/systemd/ README.md
git commit -m "feat: automated 45-day cert rotation via Cloudflare DNS-01

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Final verification (after all tasks)

- [ ] `docker compose config >/dev/null && echo OK` → `OK`
- [ ] `bash -n run.sh && bash -n renew-cert.sh && echo OK` → `OK`
- [ ] `git log --oneline -6` shows the six task commits on branch `TERRY`
- [ ] Operator smoke test (manual, off-repo): `sudo bash run.sh`; `pbx.ieisi.org` resolves to `fcd1::beef` on the LAN and serves a valid TLS cert; a Yealink phone auto-provisions from `https://pbx.ieisi.org/`; an IPv6 phone registers; an IPv4 trunk call to/from `103.51.112.38` completes with two-way audio on RTP `56600-56800`.
- [ ] Renewal automation (operator): `systemctl list-timers freepbx-cert-renew.timer` shows it scheduled; `renew-cert.sh` dry-run (`docker compose exec -T freepbx certbot renew --dry-run`) succeeds via the Cloudflare DNS plugin; `renew_before_expiry = 45 days` is present in the renewal config.
