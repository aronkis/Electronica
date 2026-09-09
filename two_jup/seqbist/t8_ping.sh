#!/bin/bash
set -u
D=$(cd "$(dirname "$0")/.." && pwd); W=$D/anyssh.sh
echo "146: $($W 10.0.0.146 'echo TUN=$(pgrep -x qpsk_tun | tr "\n" ",") IF=$(ip link show tun0 >/dev/null 2>&1 && echo up || echo none)' 2>&1 | tr -d '\r')"
