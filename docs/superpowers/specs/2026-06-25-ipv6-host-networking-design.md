# Design: Host-networked dual-stack FreePBX (internal IPv6)

**Date:** 2026-06-25
**Branch:** TERRY
**Status:** Approved design, pending implementation plan

## Goal

Let internal phones reach FreePBX over **IPv6** (and IPv4) on an already
dual-stack LAN, by moving the `freepbx` container to **host networking** so it
binds directly to the host's LAN interfaces. The external SIP trunk stays IPv4
and is port-forwarded to the PBX by the site's Mikrotik RB5009 firewall.

## Environment (given)

- LAN is dual-stack (IPv4 + IPv6) behind a Mikrotik RB5009.
- Internal phones and FreePBX both sit on that LAN.
- External SIP trunk is IPv4-only, reached via Mikrotik IPv4 port-forward to the PBX.
- Today FreePBX runs on a Docker bridge (`172.18.0.0/16`, static `.20`) with
  iptables DNAT in `run.sh` to expose the RTP media ports.

## Why host networking

Docker bridge NAT mangles the large RTP UDP port range and forces fragile DNAT
rules (the current `run.sh` logic). On host networking Asterisk binds straight
to the LAN interface: RTP flows directly, IPv6 reaches the PBX natively, and the
DNAT rules become unnecessary. The only intentional NAT left is the Mikrotik
IPv4 trunk port-forward.

## Architecture changes

### `docker-compose.yaml`

- **`freepbx`**: set `network_mode: host`. Remove the `ports:` block (illegal and
  unnecessary under host net — 80/443 tcp and 5060 udp bind to host interfaces on
  both IPv4 and IPv6). Remove the `networks:`/static-IP assignment.
- **`db`**: stays on the `defaultnet` bridge but drops the static
  `ipv4_address: 172.18.0.10`. Add `ports: ["127.0.0.1:3306:3306"]` so it is
  reachable only from host loopback, never from the LAN.
- **`fail2ban`**: unchanged (already host net; now bans on real host interfaces).
- The `defaultnet` bridge definition is retained for `db`.

### `run.sh` — reduce to a thin wrapper

- Delete: egress-interface detection (`get_default_iface`), the `DOCKER-USER`
  ACCEPT rule, the `PREROUTING` DNAT rule, and the `--rtp` argument parsing
  (no longer applied to anything).
- Keep: `--install-freepbx` and `--clean-all` helpers, and a plain
  `docker compose up -d` for the default invocation.
- `--install-freepbx`: change `--dbhost=db` → `--dbhost=127.0.0.1`.
- `--clean-all`: unchanged container/volume/network teardown.

### Database connectivity

- FreePBX (host net) connects to MariaDB at `127.0.0.1:3306` via the published
  port. MariaDB sees the connection arriving from the Docker gateway, matched by
  the existing `freepbxuser'@'%'` grant in `init.sql`.
- **No change to `init.sql` or `my.cnf`.**

## Dual-stack binding requirement (80/443/5060)

Under host networking, Docker no longer governs which address family a port binds
to — the application does. All three service ports MUST listen on **both** IPv4
and IPv6:

- **80/tcp, 443/tcp (Apache):** Apache must have `Listen 80` / `Listen 443`
  without an IPv4-only address prefix so it binds dual-stack (it listens on `::`
  and accepts v4-mapped connections, or has explicit `Listen [::]:80` lines).
  Documented as a verification step (check `ss -tlnp 'sport = :80'` shows `*` /
  `[::]`).
- **5060/udp (Asterisk PJSIP):** requires **two** PJSIP transports — one bound to
  `0.0.0.0:5060` (IPv4) and one bound to `[::]:5060` (IPv6). FreePBX ships only
  the IPv4 one by default.

## Asterisk / FreePBX-level configuration (README documentation only)

These live in the `etc_data` / `var_data` volumes (FreePBX web UI / PJSIP
settings), not in repo files. The README will gain a section documenting:

1. **Dual-stack SIP transports** — keep the default IPv4 PJSIP transport
   (`0.0.0.0:5060`) and add a second transport bound to `[::]:5060` so phones
   register over IPv6. Confirm Apache binds 80/443 dual-stack.
2. **IPv4 trunk NAT** — on the IPv4 transport / trunk, set
   `external_signaling_address` and `external_media_address` to the Mikrotik's
   public IPv4, and `local_net` to the LAN ranges (IPv4 and IPv6). This makes the
   port-forwarded IPv4 trunk advertise the public address in SDP while internal
   IPv6 phones receive the native LAN address.

## Mikrotik RB5009 firewall fragments (new deliverable)

Add `docs/mikrotik-rb5009-firewall.md` containing copy-paste RouterOS v7
fragments (with placeholder variables the operator substitutes):

- **IPv4 trunk port-forward** (`/ip firewall nat`): DNAT 5060/udp + RTP range
  from the WAN public IPv4 to the PBX LAN IPv4.
- **IPv4 filter** (`/ip firewall filter`): allow established/related and the
  forwarded trunk ports to the PBX.
- **IPv6 filter** (`/ipv6 firewall filter`): allow internal phones (LAN IPv6
  prefix) to reach the PBX on 5060/udp + RTP + 80/443, and drop unsolicited
  inbound IPv6 from WAN to the PBX.
- Address-list and interface-list placeholders so the operator maps them to
  their actual WAN/LAN interfaces and prefixes.

The fragments are documentation/configuration the operator applies on the router;
they are not executed by this repo.

## README updates

- Replace the "Ports / RTP iptables" narrative (sections describing DNAT and
  `iptables-persistent`) with the host-networking model.
- Update the Usage steps: `sudo bash run.sh` no longer configures iptables; it
  just builds and starts the stack.
- Add the Asterisk IPv6 transport + IPv4 trunk-NAT configuration section above.
- Note the new DB exposure model (`127.0.0.1:3306` only).
- Link to the new `docs/mikrotik-rb5009-firewall.md` from the README.

## Out of scope (YAGNI)

- IPv6 on the external SIP trunk (stays IPv4 by design).
- IPv6 on the internal Docker bridge for `db` (db is loopback-only).
- Making any IPv6 firewall changes on the Mikrotik (operator task, not repo).
- Automated provisioning of the PJSIP transports (manual via FreePBX UI).

## Verification

- `docker compose config` parses cleanly after edits.
- `bash -n run.sh` passes (syntax).
- Manual smoke (operator): stack starts, web UI reachable over LAN IPv6, an
  IPv6 phone registers, IPv4 trunk call completes with two-way audio.

## Risks

- Host networking exposes 80/443/5060 on all host interfaces; the Mikrotik
  firewall must gate external access (already the case for the trunk).
- If MariaDB's published port were ever set to `0.0.0.0` instead of `127.0.0.1`,
  the DB would be exposed to the LAN — the `127.0.0.1:` prefix is load-bearing.
- fail2ban already operates on the host; behaviour is unchanged but should be
  re-confirmed after the switch.
