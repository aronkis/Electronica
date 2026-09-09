#!/bin/bash
# witness_read.sh -- RXFIX Task 3 (T0c, happy-bubbling-owl): read the free instruments
# the survey named -- the Preamble_Detector realignment FIFO witness words (FIFO.v:
# 214-253, witA/witB, nominally at AXI 0x20C/0x210) and Rate_Handle's beatobs pointers
# (beatobsRhCtr/beatobsPush/beatobsPop, packed via BoDtc5/6/7 in QPSK_Rx.v) -- once per
# >=10 s, printing one JSON line per reading.
#
# CONSUMER-OWNERSHIP FINDING (desk, [netlist], this task): on the image lineage
# flashed on 148 (seqbist a1ff3c876d91, which derives from txfixF3 -- both builds'
# TxRxCompo_ip_src_QPSK_Rx.v are byte-identical at the lines below), NEITHER
# instrument is AXI-readable. Traced directly in the generated netlist (not the
# hdlsrc mirror comments, which are stale):
#
#   FIFO witness (0x20C/0x210): the 2026-08-29 comment in QPSK_Rx.v:719-721 says these
#   addresses were "re-purposed as the beat witness read-back", but the actual RTL
#   (jupiter_byte_seqbist_build/.../TxRxCompo_ip_src_QPSK_Rx.v:816,818) wires the
#   registers that land on 0x20C/0x210 (beatfix_viol_count/beatfix_viol_latch, per
#   TxRxCompo_ip_addr_decoder.v read_reg_beatfix_viol_count/_latch) to
#   `fixctl[13] ? mdcapl : dcapl` / `... : dcmm` -- the 2026-08-30 DBGCAP per-stage
#   decision capture registers, NOT witA/witB. The Preamble_Detector FIFO's own
#   witA/witB output nets (TxRxCompo_ip_src_Preamble_Detector.v:350-351, driven at
#   TxRxCompo_ip_src_FIFO.v:251-252) are declared and driven inside QPSK_Rx.v
#   (`pdWitA`/`pdWitB`, lines 190-191, 386-387) but connected to NOTHING else --
#   no assign, no output port. They are computed and dropped on the floor; there is
#   no address that reads them on this image. NOT_AVAILABLE is correct, not a
#   placeholder for "didn't look".
#
#   Rate_Handle beatobs pointers: beatobsRhCtr/beatobsPush/beatobsPop (packed into
#   BoDtc5_out1/BoDtc6_out1/BoDtc7_out1, QPSK_Rx.v:693,695,697) feed dbgI1/dbgQ1 ->
#   BoOutDtcI_out1/Q1 -> beatobsI1/Q1, which Receiver.v (:623,625) and
#   TxRxComposite.v (:1044,1072 debugI1/debugQ1) route STRAIGHT to
#   dut_data_out_0_rx/dut_data_out_1_rx (TxRxCompo_ip.v:355,357) -- the RX I/Q SAMPLE
#   STREAM to the DMA, not an AXI-lite register. There is no direct_reg_access address
#   for it: it is only observable via a DDRCAP-style stream capture (a different,
#   heavier instrument than a 10 s register poll), so a periodic direct_reg_access
#   read cannot see it either. NOT_AVAILABLE, same reasoning.
#
# Both findings are cited by exact file:line above and are falsifiable: re-run the
# same grep chain against a different image's hdl_prj_jupiter_composite tree before
# trusting this script's NOT_AVAILABLE on any image other than seqbist/txfixF3.
#
# K=V: BOARD=148|146 (required)   N=<readings> (required, >=1)   PERIOD=10 (floor 10,
#      "no faster than once per 10 s" per the brief -- any lower value is clamped up
#      with a logged warning, never silently honoured)   DRY=1(default)   OUT=<dir>
#
# DRY=1: zero ssh/scp. N JSON lines are emitted immediately (no real sleeps) with
# "dry":true; the NOT_AVAILABLE verdict and its reason are identical in DRY and real
# mode because they follow from the flashed netlist, not from anything read live.
# DRY=0: still zero network for the witness values themselves (nothing to read), but
# probes board reachability once via anyssh.sh (a benign, already-documented
# read-only devmem probe of 0x9D410000, the same register stage3h_reader.sh reads)
# so a genuinely unreachable board is reported rather than silently NOT_AVAILABLE.
set -u
D=$(cd "$(dirname "$0")" && pwd)          # two_jup/rxfix
TJ=$(cd "$D/.." && pwd)                   # two_jup
W=$TJ/anyssh.sh
DRY=${DRY:-1}
BOARD=${BOARD:?usage: BOARD=148|146 N=<readings> witness_read.sh}
N=${N:?usage: BOARD=148|146 N=<readings> witness_read.sh}
PERIOD=${PERIOD:-10}

case "$BOARD" in
  148) BRD=10.0.0.148 ;;
  146) BRD=10.0.0.146 ;;
  *) echo "BOARD must be 148 or 146" >&2; exit 2 ;;
esac
case "$N" in ''|*[!0-9]*|0) echo "N must be a positive integer" >&2; exit 2 ;; esac

PERIOD_WARN=""
if [ "$PERIOD" -lt 10 ] 2>/dev/null; then
  PERIOD_WARN="PERIOD=$PERIOD requested < 10s floor, clamped to 10"
  PERIOD=10
fi

TS=$(date +%Y%m%d_%H%M%S)
OUT=${OUT:-$D/runs/${TS}_witness_${BOARD}}
mkdir -p "$OUT"
log(){ echo "$(date -Is) $*" >> "$OUT/run.log"; }
[ -n "$PERIOD_WARN" ] && log "WARN: $PERIOD_WARN"
log "=== witness_read.sh: board=$BOARD ($BRD) n=$N period=${PERIOD}s dry=$DRY -> $OUT ==="

FIFO_REASON="0x20C/0x210 owned by DBGCAP capture (beatfix_viol_count/latch = fixctl[13]?mdcapl:dcapl per TxRxCompo_ip_src_QPSK_Rx.v:816,818); Preamble_Detector's pdWitA/pdWitB nets are unconnected to any AXI output in this image (QPSK_Rx.v:190-191,386-387)"
BEATOBS_REASON="beatobsRhCtr/Push/Pop route to debugI1/debugQ1 -> dut_data_out_0/1_rx (the RX I/Q sample stream to the DMA, TxRxCompo_ip.v:355,357), not an AXI-lite register; no direct_reg_access address exists for it in this image"

REACHABLE="unknown"
if [ "$DRY" = 0 ]; then
  DM='DM=$(command -v devmem || echo "busybox devmem")'
  if PROBE=$($W "$BRD" "$DM; \$DM 0x9D410000" 2>/dev/null | tr -d '\r'); [ -n "$PROBE" ]; then
    REACHABLE="1"; log "board reachable, tgen ctrl (benign probe) = $PROBE"
  else
    REACHABLE="0"; log "!!! board NOT reachable (probe of 0x9D410000 failed) -- NOT_AVAILABLE below is a network fact, not a netlist one"
  fi
else
  log "[dry] would probe board reachability via anyssh.sh devmem 0x9D410000 (skipped, zero board contact)"
fi

emit(){
  local seq=$1 t=$2
  printf '{"ts":"%s","seq":%d,"board":%s,"dry":%s,"reachable":%s,"fifo_witA":"NOT_AVAILABLE","fifo_witB":"NOT_AVAILABLE","fifo_reason":"%s","beatobs":"NOT_AVAILABLE","beatobs_reason":"%s"}\n' \
    "$t" "$seq" "$BOARD" "$([ "$DRY" = 1 ] && echo true || echo false)" \
    "$([ "$REACHABLE" = unknown ] && echo null || echo "\"$REACHABLE\"")" \
    "$FIFO_REASON" "$BEATOBS_REASON"
}

READINGS=$OUT/readings.jsonl; : > "$READINGS"
i=1
while [ "$i" -le "$N" ]; do
  T=$(date -Is)
  LINE=$(emit "$i" "$T")
  echo "$LINE" | tee -a "$READINGS"
  if [ "$DRY" = 0 ] && [ "$i" -lt "$N" ]; then
    sleep "$PERIOD"
  fi
  i=$((i+1))
done

{
  echo "board=$BOARD n=$N period=$PERIOD dry=$DRY reachable=$REACHABLE"
  echo "fifo_witness=NOT_AVAILABLE beatobs=NOT_AVAILABLE"
  echo "fifo_reason=$FIFO_REASON"
  echo "beatobs_reason=$BEATOBS_REASON"
  echo "ts=$(date -Is)"
} > "$OUT/meta.txt"

log "WITNESS_READ_DONE $OUT ($N readings)"
echo "WITNESS_READ_DONE $OUT"
