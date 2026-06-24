# Host-Networked Dual-Stack FreePBX Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the FreePBX container to host networking so internal phones reach it over native dual-stack (IPv4 + IPv6) on the LAN, keep the IPv4 SIP trunk working via Mikrotik port-forward, and ship operator docs for the router firewall.

**Architecture:** `freepbx` switches to `network_mode: host` (binds 80/443/5060 directly on host interfaces, dual-stack). `db` stays on the Docker bridge but publishes `127.0.0.1:3306` only. `run.sh` drops all iptables/DNAT logic (host networking makes it obsolete) and becomes a thin compose wrapper. README and a new Mikrotik RB5009 doc capture the Asterisk-level and router-level configuration.

**Tech Stack:** Docker Compose, MariaDB 10.11, FreePBX 17 / Asterisk 21 (PJSIP), Apache 2.4, RouterOS v7.

## Global Constraints

- External SIP trunk stays IPv4-only; reached via Mikrotik IPv4 port-forward. Do NOT add IPv6 trunk config.
- `db` MUST publish only to `127.0.0.1` — never `0.0.0.0`. The `127.0.0.1:` prefix is load-bearing.
- 80/tcp, 443/tcp, 5060/udp MUST bind dual-stack (both IPv4 and IPv6).
- RTP media port range default: `16384-32767/udp`.
- `init.sql` and `my.cnf` MUST NOT change — the existing `freepbxuser'@'%'` grant already covers TCP from `127.0.0.1`.
- No code is executed against the live router by this repo; RouterOS fragments are documentation only.
- Conventional Commits; one commit per task.

## File Structure

- `docker-compose.yaml` — modify: `freepbx` → host net, `db` → bridge + localhost-published port.
- `run.sh` — rewrite: thin wrapper (install / clean / up), drop iptables.
- `README.md` — modify: replace ports/iptables narrative, update usage, add Asterisk dual-stack + trunk-NAT section, link router doc.
- `docs/mikrotik-rb5009-firewall.md` — create: RouterOS v7 firewall fragments.

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

### Task 3: Add the Mikrotik RB5009 firewall fragments doc

**Files:**
- Create: `docs/mikrotik-rb5009-firewall.md`

**Interfaces:**
- Produces: a doc path linked from README in Task 4.

- [ ] **Step 1: Create `docs/mikrotik-rb5009-firewall.md`**

Write the file with this content:

````markdown
# Mikrotik RB5009 (RouterOS v7) firewall fragments

Copy-paste fragments for exposing the host-networked FreePBX. The IPv4 SIP trunk
is port-forwarded (DNAT) from the WAN; internal phones reach the PBX over IPv6
directly through the `forward` chain. Substitute every `<PLACEHOLDER>` and verify
rule ordering (RouterOS evaluates top-down; these must sit **above** your default
`drop` rules).

## Placeholders

| Placeholder | Meaning | Example |
| --- | --- | --- |
| `<PBX_LAN_IPV4>` | PBX host LAN IPv4 | `192.168.88.10` |
| `<PBX_LAN_IPV6>` | PBX host LAN IPv6 (GUA or ULA) | `2001:db8:abcd:88::10` |
| `<LAN_IPV6_PREFIX>` | Internal phone IPv6 subnet | `2001:db8:abcd:88::/64` |
| `<TRUNK_SRC_IPV4>` | SIP trunk provider source IPv4 (optional restriction) | `203.0.113.5` |
| WAN / LAN | Your interface-list names | `WAN` / `LAN` |

RTP media range matches the FreePBX default `16384-32767/udp`.

## 1. IPv4 — DNAT the trunk to the PBX

```routeros
/ip firewall nat
add chain=dstnat in-interface-list=WAN protocol=udp dst-port=5060 \
    src-address=<TRUNK_SRC_IPV4> action=dst-nat \
    to-addresses=<PBX_LAN_IPV4> to-ports=5060 \
    comment="FreePBX: SIP trunk signalling"
add chain=dstnat in-interface-list=WAN protocol=udp dst-port=16384-32767 \
    src-address=<TRUNK_SRC_IPV4> action=dst-nat \
    to-addresses=<PBX_LAN_IPV4> \
    comment="FreePBX: RTP media"
```

> Drop the `src-address=<TRUNK_SRC_IPV4>` clause only if your provider uses
> multiple/unknown media source IPs; restricting it is safer.

## 2. IPv4 — allow the forwarded traffic

```routeros
/ip firewall filter
add chain=forward connection-state=established,related action=accept \
    comment="FreePBX: established/related"
add chain=forward connection-nat-state=dstnat protocol=udp dst-port=5060 \
    dst-address=<PBX_LAN_IPV4> action=accept comment="FreePBX: SIP trunk in"
add chain=forward connection-nat-state=dstnat protocol=udp dst-port=16384-32767 \
    dst-address=<PBX_LAN_IPV4> action=accept comment="FreePBX: RTP in"
```

## 3. IPv6 — internal phones to the PBX, block WAN inbound

```routeros
/ipv6 firewall address-list
add list=pbx-host address=<PBX_LAN_IPV6> comment="FreePBX host"
add list=lan-phones address=<LAN_IPV6_PREFIX> comment="Internal phones"

/ipv6 firewall filter
add chain=forward connection-state=established,related action=accept \
    comment="FreePBX v6: established/related"
add chain=forward src-address-list=lan-phones dst-address-list=pbx-host \
    protocol=udp dst-port=5060 action=accept comment="FreePBX v6: SIP from phones"
add chain=forward src-address-list=lan-phones dst-address-list=pbx-host \
    protocol=udp dst-port=16384-32767 action=accept comment="FreePBX v6: RTP from phones"
add chain=forward src-address-list=lan-phones dst-address-list=pbx-host \
    protocol=tcp dst-port=80,443 action=accept comment="FreePBX v6: web UI from phones"
add chain=forward in-interface-list=WAN dst-address-list=pbx-host action=drop \
    comment="FreePBX v6: drop unsolicited WAN inbound"
```

## Notes

- The IPv6 trunk is intentionally NOT configured; the trunk stays IPv4 via DNAT.
- After adding rules, confirm placement with `/ip firewall filter print` and
  `/ipv6 firewall filter print` so they precede any default drop.
- The PBX itself is firewalled by fail2ban (host-networked) in addition to these
  router rules.
````

- [ ] **Step 2: Verify the doc renders and has the required sections**

Run: `grep -cE "^/ip firewall nat|^/ip firewall filter|^/ipv6 firewall filter" docs/mikrotik-rb5009-firewall.md`
Expected: prints `3` (one of each chain block present).

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
| `16384-32767/udp` | RTP      | dual-stack (IPv4 + IPv6) |

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
   **public IPv4**, and `local_net` to your LAN ranges (both the IPv4 subnet and
   the IPv6 prefix). The port-forwarded IPv4 trunk then puts the public address
   in SDP, while internal IPv6 phones receive the native LAN address.
3. **Verify dual-stack listeners** on the host:
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

## Final verification (after all tasks)

- [ ] `docker compose config >/dev/null && echo OK` → `OK`
- [ ] `bash -n run.sh && echo OK` → `OK`
- [ ] `git log --oneline -4` shows the four task commits on branch `TERRY`
- [ ] Operator smoke test (manual, off-repo): `sudo bash run.sh`; web UI reachable over LAN IPv6; an IPv6 phone registers; an IPv4 trunk call completes with two-way audio.
