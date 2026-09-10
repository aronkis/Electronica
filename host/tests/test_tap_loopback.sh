#!/bin/bash
# Host-side smoke test of the TAP (-t) data path: daemon in -l -t loopback,
# two netns with L2 TAP interfaces + fixed MACs, ping across (exercises ARP
# resolution over the link -- the thing TAP adds over TUN and that no existing
# test covered). No hardware. Needs root.
#
# TAP frames carry a 14-byte Ethernet header, so for one 280-byte air frame
# the L3 MTU is 280-12-14 = 254 (vs 268 for TUN in test_loopback.sh).
set -e
cd "$(dirname "$0")"
[ "$(id -u)" = 0 ] || { echo "SKIP (needs root)"; exit 77; }
[ -x ../qpsk_tun ] || { echo "build qpsk_tun first"; exit 1; }

cleanup() {
    kill "$DPID" 2>/dev/null || true
    ip netns del qtA 2>/dev/null || true
    ip netns del qtB 2>/dev/null || true
}
trap cleanup EXIT

ip netns del qtA 2>/dev/null || true
ip netns del qtB 2>/dev/null || true

../qpsk_tun -l -t -i qtap0 -i qtap1 &
DPID=$!
for i in $(seq 50); do ip link show qtap0 >/dev/null 2>&1 && break; sleep 0.1; done
ip link show qtap1 >/dev/null

ip netns add qtA
ip netns add qtB
ip link set qtap0 netns qtA
ip link set qtap1 netns qtB
ip -n qtA link set qtap0 address 02:00:00:00:00:01
ip -n qtB link set qtap1 address 02:00:00:00:00:02
ip -n qtA addr add 10.98.0.1/24 dev qtap0
ip -n qtB addr add 10.98.0.2/24 dev qtap1
ip -n qtA link set qtap0 up mtu 254
ip -n qtB link set qtap1 up mtu 254
ip -n qtA link set lo up
ip -n qtB link set lo up

# ping forces ARP first (broadcast who-has) then ICMP -- both must cross the
# in-process L2 bridge.
ip netns exec qtA ping -c 10 -i 0.2 -W 2 10.98.0.2 | tail -2
# confirm ARP actually resolved (a real L2 exchange, not just cached)
ip -n qtA neigh show | grep -q '10.98.0.2.*02:00:00:00:00:02' \
    && echo "ARP resolved peer MAC" || { echo "ARP DID NOT RESOLVE"; exit 1; }
echo "TAP LOOPBACK SMOKE PASS"
