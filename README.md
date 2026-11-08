# awg2socks

An [AmneziaWG](https://github.com/amnezia-vpn/amneziawg-go) server in a single
container that sends **all client TCP and UDP traffic out through a SOCKS5 proxy**
instead of the host's network.

Point it at a SOCKS5 listener such as [Mihomo](https://github.com/MetaCubeX/mihomo)
and your routing engine decides what happens to every flow (direct, proxy chain,
reject), while AmneziaWG clients connect with stock Amnezia/AWG configs.

> **Status:** experimental. Built and tested only in small setups; read the
> [limitations](#limitations) before relying on it.

## How it works

```
AWG client ──UDP──► [ awg2socks container ]
                      amneziawg-go  (awg0, 10.8.0.0/24)
                           │  policy route: from 10.8.0.0/24 -> table 100
                           ▼
                      tun2socks     (tun0)
                           │  SOCKS5 (TCP CONNECT + UDP ASSOCIATE)
                           ▼
                      Mihomo / any SOCKS5 proxy ──► rules ──► DIRECT / proxy chain
```

One container runs three pieces, supervised by a small shell entrypoint under `tini`:

| Piece | Role |
|---|---|
| `amneziawg-go` | AmneziaWG device in userspace (no kernel module needed) |
| `awg` (amneziawg-tools) | Applies the peer/obfuscation config with `awg setconf` |
| `tun2socks` | Turns packets arriving on `tun0` into SOCKS5 connections |

Only packets sourced from the AWG client subnet are steered into `tun0`
(`ip rule` + a dedicated routing table). The container's own traffic, such as the
SOCKS connection and the AWG UDP socket, keeps using the normal default route, so
there is no routing loop. The dedicated table holds nothing but the `tun0`
default route, so if tun2socks or the proxy goes away, client traffic is dropped
rather than leaking out of the host (fail-closed).

If either `amneziawg-go` or `tun2socks` exits, the container exits, and
`restart: unless-stopped` brings the whole network namespace back up cleanly.

## Features

- AmneziaWG obfuscation (Jc/Jmin/Jmax, S1/S2, H1-H4, and newer parameters your pinned build supports)
- Any SOCKS5 upstream with UDP ASSOCIATE support
- Fail-closed routing
- Strict forwarding policy: only TCP and UDP are forwarded from clients
- MSS clamping to the tunnel MTU
- Tiny runtime image (Alpine)

## Limitations

- **TCP and UDP only.** ICMP (ping, traceroute), ESP, GRE, SCTP and other IP protocols
  are dropped at the container's firewall. SOCKS5 cannot carry them anyway.
- **No path-MTU discovery** for clients. Keep the MTU at 1280 (default) and rely on the MSS clamp.
- **IPv6 is not supported.** Disable it on the container (see the compose example).
- **The proxy sees one source**, the container, not individual clients, so per-client
  rules in the proxy are not possible. You get per-ingress rules instead (one listener per ingress).
- DNS needs help from the proxy. See [DNS](#dns).

## Quick start

### 1. Generate keys

```sh
docker run --rm --entrypoint awg ghcr.io/OWNER/awg2socks:latest genkey > server.key
docker run --rm -i --entrypoint awg ghcr.io/OWNER/awg2socks:latest pubkey < server.key > server.pub
# repeat for each client
```

### 2. Write the server config

Copy `awg0.conf.example` to `awg0.conf` and fill it in. It uses `awg setconf` format
(no `Address`, `DNS` or `PostUp` lines; the entrypoint handles those):

```ini
[Interface]
PrivateKey = <server private key>
ListenPort = 51820
Jc = 4
Jmin = 40
Jmax = 70
S1 = 15
S2 = 23
H1 = 1000000001
H2 = 1000000002
H3 = 1000000003
H4 = 1000000004

[Peer]
PublicKey  = <client public key>
AllowedIPs = 10.8.0.2/32
```

The obfuscation values must match the client exactly. Never commit `awg0.conf`
(it is in `.gitignore`).

### 3. Run it next to your proxy

```yaml
services:
  awg2socks:
    image: ghcr.io/OWNER/awg2socks:latest   # or: build: .
    restart: unless-stopped
    cap_add: [NET_ADMIN]
    devices:
      - /dev/net/tun:/dev/net/tun
    sysctls:
      net.ipv4.ip_forward: "1"
      net.ipv4.conf.all.rp_filter: "0"
      net.ipv4.conf.default.rp_filter: "0"
      net.ipv6.conf.all.disable_ipv6: "1"
    environment:
      SOCKS_URL: socks5://mihomo:1083
    volumes:
      - ./awg0.conf:/etc/awg/awg0.conf:ro
    ports:
      - "51820:51820/udp"
    depends_on: [mihomo]
    networks: [stack]
    healthcheck:
      test: ["CMD-SHELL", "ip link show awg0 && ip link show tun0 && ip rule | grep -q 'lookup 100'"]
      interval: 30s
      timeout: 5s
      retries: 3

  mihomo:
    image: metacubex/mihomo:latest
    restart: unless-stopped
    volumes:
      - ./mihomo:/root/.config/mihomo
    networks: [stack]
    # do NOT publish the awg2socks SOCKS listener (1083) to the host

networks:
  stack: {}
```

### 4. Add the listener to Mihomo

A sketch to adapt to your config (check it with `mihomo -t`):

```yaml
listeners:
  - name: awg-in
    type: socks
    listen: 0.0.0.0        # reachable on the compose network only
    port: 1083
    udp: true
    rule: awg-rules        # per-ingress routing

proxies:
  - name: dns-out
    type: dns

dns:
  enable: true
  enhanced-mode: fake-ip
  # ...your nameservers / nameserver-policy

sub-rules:
  awg-rules:
    - AND,((NETWORK,UDP),(DST-PORT,53)),dns-out   # answer client DNS with Mihomo's own resolver
    - IP-CIDR,10.0.0.0/8,REJECT,no-resolve        # keep clients away from the compose network / LAN
    - IP-CIDR,172.16.0.0/12,REJECT,no-resolve
    - IP-CIDR,192.168.0.0/16,REJECT,no-resolve
    - IP-CIDR,127.0.0.0/8,REJECT,no-resolve
    # ...your usual rules...
    - MATCH,Output                                 # your outbound proxy group
```

### 5. Client config

A standard AWG client, with the same obfuscation values as the server:

```ini
[Interface]
PrivateKey = <client private key>
Address    = 10.8.0.2/32
DNS        = 1.1.1.1
MTU        = 1280
Jc = 4
Jmin = 40
Jmax = 70
S1 = 15
S2 = 23
H1 = 1000000001
H2 = 1000000002
H3 = 1000000003
H4 = 1000000004

[Peer]
PublicKey  = <server public key>
Endpoint   = your.server.example:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
```

## DNS

tun2socks carries only TCP/UDP flows, so a client's DNS query reaches the proxy as an
ordinary UDP flow to `<some IP>:53`. Without extra handling the proxy would forward it
to that resolver and bypass its own DNS. The `dns-out` rule above hands those queries
to Mihomo's built-in resolver instead (fake-ip, `nameserver-policy` and domain rules
then work as usual). Set the client's `DNS` to any public address; it never actually
receives the query. DNS over HTTPS/TLS inside the client bypasses all of this.

## Configuration

Environment variables of the container:

| Variable | Default | Description |
|---|---|---|
| `SOCKS_URL` | *(required)* | Upstream SOCKS5, e.g. `socks5://mihomo:1083` |
| `AWG_IF` | `awg0` | AmneziaWG interface name |
| `AWG_CONF` | `/etc/awg/awg0.conf` | Config in `awg setconf` format |
| `AWG_ADDR` | `10.8.0.1/24` | Server address and client subnet |
| `CLIENT_SUBNET` | `10.8.0.0/24` | Source range steered into tun2socks (match `AWG_ADDR`) |
| `AWG_MTU` | `1280` | MTU of the AWG interface |
| `T2S_DEV` | `tun0` | tun2socks device name |
| `T2S_ADDR` | `10.255.255.1/30` | Address on the tun2socks device |
| `T2S_MTU` | `$AWG_MTU` | tun2socks MTU |
| `T2S_LOGLEVEL` | `info` | tun2socks log level |
| `TABLE` | `100` | Routing table used for client traffic |

## Building

```sh
docker build -t awg2socks .
```

Build arguments (pin them to versions you have tested):

| Argument | Description |
|---|---|
| `AWG_GO_REF` | Tag of `amnezia-vpn/amneziawg-go` |
| `AWG_TOOLS_REF` | Tag of `amnezia-vpn/amneziawg-tools` |
| `T2S_VERSION` | Version of `xjasonlyu/tun2socks` |
| `GO_IMAGE` | Go builder image (must satisfy `amneziawg-go`'s `go.mod`) |
| `ALPINE_VERSION` | Alpine base for the tools stage and runtime |

A GitHub Actions workflow (`.github/workflows/docker.yml`) builds and publishes the
image to `ghcr.io/OWNER/awg2socks`: `latest` and `sha-*` on `main`, version tags on `v*`.

## Security notes

- Keep the SOCKS listener on the internal compose network. It is unauthenticated.
- Reject private ranges for this ingress in the proxy (as in the sub-rule above), or
  clients can reach other containers and your LAN through it.
- Keep `awg0.conf` and key files out of version control.
- Client-to-client traffic and anything aimed at the container itself is dropped.

## Credits

Built on [amneziawg-go](https://github.com/amnezia-vpn/amneziawg-go),
[amneziawg-tools](https://github.com/amnezia-vpn/amneziawg-tools) and
[tun2socks](https://github.com/xjasonlyu/tun2socks).

## License

Add a license of your choice before publishing. Note that bundled components keep their own licenses.
