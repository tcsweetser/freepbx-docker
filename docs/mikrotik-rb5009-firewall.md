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
