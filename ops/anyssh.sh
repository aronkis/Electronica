#!/bin/sh
# usage: anyssh.sh <ip> '<remote cmd>'
IP="$1"; shift
# Resolve the askpass helper next to THIS script (portable across sessions).
D=$(cd "$(dirname "$0")" && pwd)
SSH_ASKPASS="$D/askpass.sh" SSH_ASKPASS_REQUIRE=force DISPLAY=:0 \
  setsid -w ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 \
  -o PreferredAuthentications=password -o PubkeyAuthentication=no \
  root@"$IP" "$@" < /dev/null
