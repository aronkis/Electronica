#!/bin/bash
# =============================================================================
# test.sh <tier> [options] -- unified entry point for the QPSK K5 modem test
# suite. THIN dispatcher over the proven keepers (no new test logic). See
# docs/testing.rst for the acceptance ladder and how to read each result.
#
# Tiers:
#   loopback  TIER A self-loopback, NO RF. Host unit tests (dev box, always) +
#             on-board internal FPGA loopback rx_input_select=0 (if -A reachable).
#   bist      TIER B on-chip BIST comparator: measure_ber.sh (golden cap_out
#             0x04922282 + counter-delta BER). Read it during an active link/arm.
#   ber       TIER B host full-packet scorer: link_test.sh ber (CLEAN/NOISY/
#             PHASE/ROTATED/MISS buckets + BER, two-board).
#   link      TIER C real data over a real link:
#               --radios 2  two-board FDD quiet pair  (link_test.sh ber)
#               --radios 1  single-board RF loopback  (rf_loopback.sh; needs a
#                           Tx->Rx cable/attenuator -- prints the ready procedure)
#   all       acceptance ladder: host tests -> preflight -> ber.
#
# Options: -A <ipA=10.0.0.148>  -B <ipB=10.0.0.146>  --radios <1|2>
#          -n <bist reads=200>  -d <ber secs=60>  -h
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd)
HOST_APP="$D/../host"
A_IP=${A_IP:-10.0.0.148}; B_IP=${B_IP:-10.0.0.146}
RADIOS=2; NREADS=200; DUR=60

usage(){ sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; }
reachable(){ "$D/anyssh.sh" "$1" 'echo up' 2>/dev/null | grep -q up; }
hr(){ echo; echo "=== $* ==="; }

SUB=${1:-}; [ -n "$SUB" ] && shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    -A) A_IP=$2; shift 2;;
    -B) B_IP=$2; shift 2;;
    --radios) RADIOS=$2; shift 2;;
    -n) NREADS=$2; shift 2;;
    -d) DUR=$2; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "unknown option: $1" >&2; usage; exit 2;;
  esac
done

case "$SUB" in
  loopback)
    hr "TIER A -- host unit tests (dev box, no hardware)"
    PATH=/usr/bin:$PATH make -C "$HOST_APP" test
    hr "TIER A -- on-board internal FPGA loopback (rx_input_select=0, no RF) on $A_IP"
    if reachable "$A_IP"; then
      "$D/ber_loopback_gate.sh" "$A_IP"
    else
      echo "SKIP: $A_IP not reachable via anyssh.sh (host unit tests above still valid)."
    fi
    ;;

  bist)
    hr "TIER B -- on-chip BIST comparator on $A_IP ($NREADS reads)"
    echo "(reads cap_out 0x144 golden 0x04922282 + BIST counter-delta BER;"
    echo " most meaningful during an active link/loopback arm -- see docs/testing.rst)"
    "$D/measure_ber.sh" "$A_IP" "$NREADS"
    ;;

  ber)
    hr "TIER B -- host full-packet scorer (two-board), dur=${DUR}s"
    "$D/link_test.sh" ber -d "$DUR" -A "$A_IP" -B "$B_IP"
    ;;

  link)
    if [ "$RADIOS" = 2 ]; then
      hr "TIER C -- real data, TWO radios (FDD quiet pair)"
      "$D/link_test.sh" ber -d "$DUR" -A "$A_IP" -B "$B_IP"
      echo
      echo "next (interactive IP / SSH over the same link):"
      echo "  ./link_test.sh tun          # tun0 both ways, leave up"
      echo "  ./link_test.sh ssh          # ssh B->A over tun0 (RF-SSH-OK)"
    elif [ "$RADIOS" = 1 ]; then
      hr "TIER C -- real data, ONE radio (single-board RF loopback)"
      cat <<EOF
Single-radio RF loopback exercises the REAL RF chain on ONE board:
    DAC -> PA -> [external Tx1->Rx1 cable + ~30-40 dB attenuator] -> LNA -> ADC

PHYSICAL PREREQUISITE: cable board $A_IP's Tx1 output to its own Rx1 input
through an attenuator (a bare LNA can be saturated/damaged by Tx 0 dBFS).

Ready-to-run once the cable is rigged (Tx LO == Rx LO):
    ./rf_loopback.sh $A_IP 2000        # 60s -B RF-loopback BER at 2.00 GHz

Healthy result mirrors the two-board 'ber' test (CLEAN high, low BER). This mode
is documented ready-to-run but was NOT hardware-validated in this kit (no cable).
EOF
    else
      echo "link: --radios must be 1 or 2 (got '$RADIOS')" >&2; exit 2
    fi
    ;;

  all)
    hr "ACCEPTANCE LADDER -- host tests -> preflight -> ber"
    PATH=/usr/bin:$PATH make -C "$HOST_APP" test
    "$D/link_test.sh" preflight -A "$A_IP" -B "$B_IP"
    "$D/link_test.sh" ber -d "$DUR" -A "$A_IP" -B "$B_IP"
    ;;

  -h|--help|"") usage; exit 0;;
  *) echo "unknown tier: '$SUB'" >&2; usage; exit 2;;
esac
