#!/bin/bash
# =============================================================================
# loop_sweep.sh <board-ip> [dwell_s] -- live sweep of the T9.0 clamped loop-tune
# AXI registers against delivered link health. NO REBUILD, NO FLASH.
#
# Requires an image built with QPSK_LOOP_TUNE=1 (regs 0x1F0-0x204). Every write
# is CLAMPED IN FABRIC to a safe band, so a bad value mistunes but cannot unlock
# the loop -- that is what makes an on-air sweep safe to automate. Register 0
# always restores the compiled default, and the script restores 0 on exit
# (including on Ctrl-C) so the link never stays mistuned.
#
#   0x1F0 lt_cs_prop_gain   ufix16_En16  dflt SI 98        clamp [12, 784]
#   0x1F4 lt_cs_integ_gain  ufix16_En16  dflt SI 1         clamp [1, 64]
#   0x1F8 lt_ss_prop_gain   sfix24_En24  dflt SI -163506   clamp [-1308048, -20438]
#   0x1FC lt_ss_integ_gain  sfix24_En24  dflt SI -2180     clamp [-17440, -272]
#   0x200 lt_agc_loop_gain  ufix32_En31  dflt SI 4294967   clamp [536871, 34359738]
#   0x204 lt_cfo_threshold  sfix22_En21  dflt SI 26214     clamp [3300, 209712]
#
# Loop BANDWIDTH is set by the prop/integ PAIR, so the carrier and timing sweeps
# write both members together on the standard Bn locus (prop ~ Bn, integ ~ Bn^2):
# scaling the pair by (k, k^2) moves Bn by k with damping preserved.
#
# Metric per point: frame rate from 0x104 (delta over the dwell) + crc_drop slope
# from the host daemon. A point that costs >20% of the baseline frame rate is
# reported as DEGRADED and immediately reverted -- the sweep does not linger on
# a bad operating point.
#
# SAFETY: writes go through debugfs direct_reg_access. NEVER run this across a
# profile reload / bring-up (board-hang rule); bring the link up first, let it
# settle, then sweep. Poller may run concurrently (register writes are fine;
# only profile reloads are forbidden).
#
# Usage: loop_sweep.sh 10.0.0.146 [dwell_s]     (default dwell 30 s)
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
IP=${1:?usage: loop_sweep.sh <board-ip> [dwell_s]}
DWELL=${2:-30}
OUT=$D/loopsweep/$(date +%Y%m%d_%H%M%S); mkdir -p "$OUT"
CSV=$OUT/loop_sweep.csv
DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access

wr(){ $W "$IP" "echo '$1 $2' > $DRA" 2>/dev/null; }          # reg value (hex str)
rd(){ $W "$IP" "echo $1 > $DRA; cat $DRA" 2>/dev/null; }
restore(){ echo "  restoring compiled defaults (all regs -> 0)"; for r in 0x1F0 0x1F4 0x1F8 0x1FC 0x200 0x204; do wr $r 0x0; done; }
# The on-board lock_watchdog issues FULL RE-ARM when it sees not-locked, which RESETS
# 0x104/0x150 mid-measurement and yields NEGATIVE deltas (measured 2026-08-06: it
# aborted a whole sweep with "baseline -1 f/s"). Pause it for the sweep, restore after.
# This does NOT touch profiles, so the board-hang rule is not engaged.
wd_stop(){ $W "$IP" 'pkill -f "[l]ock_watchdog"' 2>/dev/null; echo "  lock_watchdog paused for the sweep"; }
wd_start(){ $W "$IP" 'setsid nohup /root/lock_watchdog.sh </dev/null >/dev/null 2>&1 &' 2>/dev/null; echo "  lock_watchdog restarted"; }
trap 'echo; echo "INTERRUPTED"; restore; wd_start; exit 130' INT TERM

# frames/s over the dwell, measured on the fabric frame counter (0x104)
rate(){
  local p0 p1
  p0=$(rd 0x104); sleep "$DWELL"; p1=$(rd 0x104)
  python3 -c "
p0=int('${p0:-0}',16); p1=int('${p1:-0}',16)
d=p1-p0
print(int(d/${DWELL}) if d>=0 else -1)   # -1 => counter reset mid-window (invalid sample)"
}
crc(){ $W "$IP" 'tail -1 /dev/shm/qpsk_tun.log | grep -oE "crc_drop=[0-9]+" | cut -d= -f2' 2>/dev/null; }

echo "=== loop_sweep on $IP  dwell=${DWELL}s  -> $OUT ==="
echo "reg,label,value_si,rate_fps,crc_delta,verdict" > "$CSV"
wd_stop

restore
echo "--- baseline (compiled defaults) ---"
C0=$(crc); BASE=$(rate); C1=$(crc)
echo "baseline: ${BASE} f/s  crc_delta=$(( ${C1:-0} - ${C0:-0} ))"
echo "0,baseline,0,$BASE,$(( ${C1:-0} - ${C0:-0} )),BASELINE" >> "$CSV"
[ "${BASE:-0}" -gt 100 ] || { echo "FATAL: baseline rate ${BASE} f/s -- link not healthy (or a counter reset landed mid-window), aborting"; restore; wd_start; exit 1; }
FLOOR=$(( BASE * 80 / 100 ))
echo "degraded threshold: < ${FLOOR} f/s"

# ---- coordinated bandwidth sweeps: (prop, integ) scaled by (k, k^2) ----
# k expressed as a percentage to stay in integer arithmetic.
sweep_pair(){   # $1 label  $2 propReg  $3 propDflt  $4 propLo $5 propHi
                # $6 integReg $7 integDflt $8 integLo $9 integHi
  local lbl=$1 pr=$2 pd=$3 plo=$4 phi=$5 ir=$6 id=$7 ilo=$8 ihi=$9
  for kpct in 25 50 71 141 200 400; do
    local pv iv
    pv=$(python3 -c "
v=int(round($pd*$kpct/100)); lo,hi=sorted(($plo,$phi)); print(max(lo,min(hi,v)))")
    iv=$(python3 -c "
v=int(round($id*$kpct*$kpct/10000)); lo,hi=sorted(($ilo,$ihi)); print(max(lo,min(hi,v)))")
    # stored integers are written as unsigned hex of the two's-complement word
    local pvh ivh
    pvh=$(python3 -c "print(hex($pv & 0xFFFFFFFF))")
    ivh=$(python3 -c "print(hex($iv & 0xFFFFFFFF))")
    wr "$pr" "$pvh"; wr "$ir" "$ivh"
    local c0 r c1 dc verdict
    c0=$(crc); r=$(rate); c1=$(crc); dc=$(( ${c1:-0} - ${c0:-0} ))
    if [ "${r:-0}" -lt "$FLOOR" ]; then verdict=DEGRADED; else verdict=ok; fi
    printf "  %-10s Bn x%-5s prop=%-9s integ=%-9s -> %5s f/s  crc+%-6s %s\n" \
           "$lbl" "0.${kpct}" "$pv" "$iv" "$r" "$dc" "$verdict"
    echo "$pr+$ir,$lbl@${kpct}pct,$pv/$iv,$r,$dc,$verdict" >> "$CSV"
    if [ "$verdict" = DEGRADED ]; then wr "$pr" 0x0; wr "$ir" 0x0; fi
  done
  wr "$pr" 0x0; wr "$ir" 0x0
}

echo "--- carrier loop bandwidth (0x1F0 + 0x1F4) ---"
sweep_pair carrier 0x1F0 98 12 784 0x1F4 1 1 64
echo "--- timing loop bandwidth (0x1F8 + 0x1FC) ---"
sweep_pair timing 0x1F8 -163506 -1308048 -20438 0x1FC -2180 -17440 -272

# ---- single-register sweeps ----
sweep_one(){    # $1 label $2 reg $3 dflt $4 lo $5 hi
  local lbl=$1 rg=$2 df=$3 lo=$4 hi=$5
  for kpct in 25 50 200 400; do
    local v vh c0 r c1 dc verdict
    v=$(python3 -c "
v=int(round($df*$kpct/100)); lo,hi=sorted(($lo,$hi)); print(max(lo,min(hi,v)))")
    vh=$(python3 -c "print(hex($v & 0xFFFFFFFF))")
    wr "$rg" "$vh"
    c0=$(crc); r=$(rate); c1=$(crc); dc=$(( ${c1:-0} - ${c0:-0} ))
    if [ "${r:-0}" -lt "$FLOOR" ]; then verdict=DEGRADED; else verdict=ok; fi
    printf "  %-10s x%-5s si=%-10s -> %5s f/s  crc+%-6s %s\n" "$lbl" "0.${kpct}" "$v" "$r" "$dc" "$verdict"
    echo "$rg,$lbl@${kpct}pct,$v,$r,$dc,$verdict" >> "$CSV"
    [ "$verdict" = DEGRADED ] && wr "$rg" 0x0
  done
  wr "$rg" 0x0
}
echo "--- AGC loop gain (0x200) ---"
sweep_one agc 0x200 4294967 536871 34359738
echo "--- CFO step threshold (0x204) ---"
sweep_one cfo 0x204 26214 3300 209712

restore
wd_start
echo "=== done -> $CSV ==="
echo "  best points (rate >= baseline, fewest crc drops):"
sort -t, -k4 -rn "$CSV" | awk -F, '$6=="ok"' | head -5 | sed 's/^/    /'
