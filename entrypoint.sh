#!/bin/bash
# AWG ingress: amneziawg-go -> policy route -> tun2socks -> SOCKS5 listener (Mihomo).
# If either daemon dies the container exits, so `restart:` rebuilds the whole netns.
set -euo pipefail

AWG_IF=${AWG_IF:-awg0}
AWG_CONF=${AWG_CONF:-/etc/awg/awg0.conf}
AWG_ADDR=${AWG_ADDR:-10.8.0.1/24}
AWG_MTU=${AWG_MTU:-1280}
CLIENT_SUBNET=${CLIENT_SUBNET:-10.8.0.0/24}
SOCKS_URL=${SOCKS_URL:?SOCKS_URL is required, e.g. socks5://mihomo:1083}
T2S_DEV=${T2S_DEV:-tun0}
T2S_ADDR=${T2S_ADDR:-10.255.255.1/30}
T2S_MTU=${T2S_MTU:-$AWG_MTU}
T2S_LOGLEVEL=${T2S_LOGLEVEL:-info}
TABLE=${TABLE:-100}

log() { echo "[awg-in] $*"; }

pids=()
cleanup() { trap - EXIT; kill "${pids[@]}" 2>/dev/null || true; }
trap cleanup EXIT
trap 'exit 143' TERM INT

wait_for() {   # wait_for <what> <cmd...>
  local what=$1; shift
  for _ in $(seq 1 100); do
    "$@" >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  log "timed out waiting for $what"; exit 1
}

# 1) AmneziaWG device (userspace), configured with `awg setconf` format
log "starting amneziawg-go on $AWG_IF"
amneziawg-go -f "$AWG_IF" & pids+=($!)
wait_for "$AWG_IF" awg show "$AWG_IF"
awg setconf "$AWG_IF" "$AWG_CONF"
ip addr add "$AWG_ADDR" dev "$AWG_IF"
ip link set dev "$AWG_IF" mtu "$AWG_MTU" up

# 2) tun2socks: its own TUN, all flows dialed through the SOCKS5 listener
log "starting tun2socks on $T2S_DEV -> $SOCKS_URL"
tun2socks -device "tun://$T2S_DEV" -proxy "$SOCKS_URL" \
          -mtu "$T2S_MTU" -loglevel "$T2S_LOGLEVEL" & pids+=($!)
wait_for "$T2S_DEV" ip link show dev "$T2S_DEV"
ip addr add "$T2S_ADDR" dev "$T2S_DEV"
ip link set dev "$T2S_DEV" up

# 3) Only AWG clients are steered into tun2socks. The container's own traffic
#    (the SOCKS connection to Mihomo, AWG UDP on eth0) keeps using the main table,
#    so there is no routing loop. Table $TABLE holds nothing else => fail-closed.
ip rule  add from "$CLIENT_SUBNET" lookup "$TABLE" pref 100
ip route add default dev "$T2S_DEV" table "$TABLE"

# 4) Firewall: forward only TCP/UDP awg->tun2socks (+ replies); everything else
#    (ICMP, GRE, client<->client, anything aimed at the container itself) is dropped.
iptables -P FORWARD DROP
iptables -A FORWARD -i "$AWG_IF"  -o "$T2S_DEV" -p tcp -j ACCEPT
iptables -A FORWARD -i "$AWG_IF"  -o "$T2S_DEV" -p udp -j ACCEPT
iptables -A FORWARD -i "$T2S_DEV" -o "$AWG_IF"  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT   -i "$AWG_IF" -j DROP
iptables -t mangle -A FORWARD -o "$T2S_DEV" -p tcp --tcp-flags SYN,RST SYN \
         -j TCPMSS --clamp-mss-to-pmtu

log "up: $CLIENT_SUBNET -> $AWG_IF -> $T2S_DEV -> $SOCKS_URL"
wait -n || true
log "a child process exited; stopping so the orchestrator restarts the container"
exit 1
