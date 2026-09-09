#!/bin/bash
# =============================================================================
# apply_146_ssi_fix.sh <board-ip> [tx0_clk [tx0_dat]] -- apply a TX SSI delay
# override SAFELY and re-arm the modem regfile.
#
# WHY (task-TXCHAR + task-STOCKSSI): the adrv9002 driver re-runs a PRBS15 SSI
# delay auto-tune at EVERY profile load; on unit 146 (and unit 148 at 30.72)
# the PRBS test can pick a word-boundary-slip clk row that mission traffic
# cannot use. The proven override for 146 is tx0 clk=3, data/strobe=4 (works at
# 1.92 AND 30.72 -- not rate-conditional so far).
#
# *** DELAY-APPLICATION PROTOCOL (task-STOCKSSI: the write-cache trap) ***
# The per-field debugfs files (tx0_ssi_clk_delay etc.) are a WRITE CACHE:
# initialized to 0, NEVER synced from hardware. `echo 1 > ssi_delays` applies
# the ENTIRE struct from that cache -- a partial override silently ZEROES every
# field you did not populate (this destroyed the working RX delays during the
# R2 sweeps: rx0 -> clk0/dat0 = inside the RX fail band). Protocol, always:
#   (a) READ LIVE hardware state:  cat ssi_delays   (read = hardware inspect)
#   (b) write EVERY field back into the cache (all rx0/rx1/tx0/tx1 fields)
#   (c) set ONLY the intended override fields
#   (d) apply:  echo 1 > ssi_delays
#   (e) VERIFY via a fresh live read: overrides took AND untouched fields kept
#
# Then pulse modem 0x000 and re-assert 0x158/0x118/0x114 (+ tx-lpc + 0x110) to
# clear demod state (0x000 reverts the regfile -- must re-assert).
#
# GUARD: per-unit override; refuses IPs other than 10.0.0.146 unless FORCE=1
# (148 needed it too at 30.72 -- call with FORCE=1 and explicit clk/dat).
# Usage: apply_146_ssi_fix.sh [ip=10.0.0.146] [tx0_clk=3] [tx0_dat=4]
#        AIR=1 (default) | AIR=0   -> value re-asserted into 0x114
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
IP=${1:-10.0.0.146}
CLK=${2:-3}
DAT=${3:-4}
AIR=${AIR:-1}
# RXPIN="clk i q strobe" additionally PINS the rx0 delays. Unset (default) reproduces the
# historical behaviour exactly: rx0 is preserved from the live read, i.e. left at whatever
# this boot's auto-tune chose. See SW_BRINGUP_DESIGN.md -- the 16-arm experiment showed the
# receive side re-runs auto-tune every arm while only tx0 was ever pinned.
RXPIN=${RXPIN:-}
if [ "$IP" != "10.0.0.146" ] && [ "${FORCE:-0}" != 1 ]; then
  echo "REFUSE: SSI delay override is per-unit (146 default); got $IP. FORCE=1 + explicit clk/dat to override." >&2
  exit 2
fi
OUT=$($W "$IP" 'B=/sys/kernel/debug/iio/iio:device2
 # (a) live hardware read
 LIVE=$(cat $B/ssi_delays)
 get(){ echo "$LIVE" | awk -F": " -v k="$1" "\$1==k{print \$2}"; }
 # (b) populate the ENTIRE write cache from live values
 for ch in rx0 rx1 tx0 tx1; do
   echo "$(get ${ch}_ClkDelay)"     > $B/${ch}_ssi_clk_delay
   echo "$(get ${ch}_StrobeDelay)"  > $B/${ch}_ssi_strobe_delay
   echo "$(get ${ch}_rxIDataDelay)" > $B/${ch}_ssi_i_data_delay
   echo "$(get ${ch}_rxQDataDelay)" > $B/${ch}_ssi_q_data_delay
 done
 echo "$(get tx0_RefClkDelay)" > $B/tx0_ssi_refclk_delay
 echo "$(get tx1_RefClkDelay)" > $B/tx1_ssi_refclk_delay
 # (c) intended overrides only
 echo '"$CLK"' > $B/tx0_ssi_clk_delay
 echo '"$DAT"' > $B/tx0_ssi_i_data_delay
 echo '"$DAT"' > $B/tx0_ssi_q_data_delay
 echo '"$DAT"' > $B/tx0_ssi_strobe_delay
 # (c2) OPTIONAL rx0 pin (RXPIN="clk i q strobe"). Unset -> rx0 stays preserved from the
 # live read, i.e. whatever this boot auto-tune chose -- the historical behaviour.
 RXP='"$RXPIN"'
 if [ -n "$RXP" ]; then
   RC=${RXP%% *}; r=${RXP#* }; RI=${r%% *}; r=${r#* }; RQ=${r%% *}; RS=${r##* }
   echo "$RC" > $B/rx0_ssi_clk_delay
   echo "$RI" > $B/rx0_ssi_i_data_delay
   echo "$RQ" > $B/rx0_ssi_q_data_delay
   echo "$RS" > $B/rx0_ssi_strobe_delay
 fi
 # (d) apply the full struct
 echo 1 > $B/ssi_delays
 # (e) verify against a fresh live read
 LIVE2=$(cat $B/ssi_delays)
 g2(){ echo "$LIVE2" | awk -F": " -v k="$1" "\$1==k{print \$2}"; }
 ok=1
 [ "$(g2 tx0_ClkDelay)" = "'"$CLK"'" ] || ok=0
 [ "$(g2 tx0_StrobeDelay)" = "'"$DAT"'" ] || ok=0
 if [ -z "$RXP" ]; then
   for f in rx0_ClkDelay rx0_StrobeDelay rx0_rxIDataDelay rx0_rxQDataDelay; do
     [ "$(g2 $f)" = "$(get $f)" ] || { ok=0; echo "PRESERVE-FAIL $f: live=$(g2 $f) want=$(get $f)"; }
   done
 else
   [ "$(g2 rx0_ClkDelay)"     = "$RC" ] || { ok=0; echo "RXPIN-FAIL rx0_ClkDelay: live=$(g2 rx0_ClkDelay) want=$RC"; }
   [ "$(g2 rx0_rxIDataDelay)" = "$RI" ] || { ok=0; echo "RXPIN-FAIL rx0_rxIDataDelay: live=$(g2 rx0_rxIDataDelay) want=$RI"; }
   [ "$(g2 rx0_rxQDataDelay)" = "$RQ" ] || { ok=0; echo "RXPIN-FAIL rx0_rxQDataDelay: live=$(g2 rx0_rxQDataDelay) want=$RQ"; }
   [ "$(g2 rx0_StrobeDelay)"  = "$RS" ] || { ok=0; echo "RXPIN-FAIL rx0_StrobeDelay: live=$(g2 rx0_StrobeDelay) want=$RS"; }
 fi
 DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
 echo "0x000 0x1">$DRA; sleep 0.5; echo "0x000 0x0">$DRA
 echo "0x158 0x1">$DRA; echo "0x118 0x0">$DRA; echo "0x114 0x'"$AIR"'">$DRA
 TXD=$(for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name 2>/dev/null)" = axi-adrv9002-tx-lpc ] && echo ${d##*/}; done)
 T=/sys/kernel/debug/iio/$TXD/direct_reg_access
 echo "0x418 0x2">$T; echo "0x458 0x2">$T; echo "0x044 0x1">$T
 echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA
 [ $ok = 1 ] && echo "ssi-fix VERIFIED: tx0=c'"$CLK"'d'"$DAT"' rx0 preserved ($(g2 rx0_ClkDelay)/$(g2 rx0_rxIDataDelay)) (rearmed, 0x114='"$AIR"')" \
             || echo "ssi-fix VERIFY-FAIL (see PRESERVE-FAIL lines)"' 2>/dev/null)
echo "$OUT"
echo "$OUT" | grep -q 'ssi-fix VERIFIED' || { echo "FATAL: SSI fix did not verify on $IP" >&2; exit 1; }
