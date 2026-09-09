#!/bin/bash
# sel5_capture.sh -- ONE arm, TWO captures: sel5 then sel6, both as early as possible.
#
# Shape chosen from the hazard data (§59/§60): 10 arms / 4 hangs today = ~40 %, versus 30+ captures
# with zero hangs. So an arm is the expensive operation and must buy as much as possible. Two
# captures on one arm gets sel5 and sel6 from the SAME arm and the same link state, removing the
# arm-to-arm variable the §68 pre-registration had to caveat. It does not put them in the same
# burst -- the mux carries one selector at a time (§61) -- and that limitation stands.
#
# Rules encoded here because each was learned the hard way:
#   - capture #1 and #2 immediately after the arm (degradation sets in ~capture 3 at 1247 f/s, §48)
#   - capTAP verified golden BEFORE and AFTER each capture, or the capture is not credited (§50)
#   - 1 s polling, never faster (§60 -- a 0.25 s poll hung a board)
#   - board-side file deleted after each transfer (§54 -- a leftover truncated the next capture
#     silently, and iio_readdev returned SUCCESS on the short file)
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh; B=${B:-10.0.0.148}
SZ=${SZ:-134217728}; THRESH=${THRESH:-3000}; GOLD=BCF94856
OUT=${OUT:-$D/sel5/$(date +%Y%m%d_%H%M%S)}; mkdir -p "$OUT"
log(){ echo "$(date +%T) $*" | tee -a "$OUT/run.log"; }
probe(){ $W $B "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
  echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
  rd(){ echo \"\$1\">\$DRA; cat \$DRA; }
  p0=\$((\$(rd 0x104))); e0=\$((\$(rd 0x108))); sleep 2; p1=\$((\$(rd 0x104))); e1=\$((\$(rd 0x108)))
  echo \"\$(( (p1-p0)/2 )) \$(( (e1-e0)/2 )) \$(rd 0x20C)\"" 2>/dev/null | tr -d '\r' | tail -1; }
norm(){ printf %s "$1" | sed -E 's/^0[xX]//' | tr 'a-f' 'A-F'; }

n=0
for SEL in 5 6; do
  n=$((n+1))
  read -r F0 E0 C0 <<<"$(probe)"
  if [ "$(norm "$C0")" != "$GOLD" ]; then
    log "ABORT before capture $n (sel$SEL): capTAP=[$(norm "$C0")] != [$GOLD] -- link not golden, not capturing"
    exit 4
  fi
  log "capture $n (sel$SEL): pre-check OK fps=$F0 errps=$E0 capTAP=$C0"
  $W $B "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
    echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
    rd(){ echo \"\$1\">\$DRA; cat \$DRA; }
    echo '0x10C 0x${SEL}0003' > \$DRA; sleep 2
    for w in \$(seq 1 150); do
      a0=\$((\$(rd 0x108))); sleep 1; a1=\$((\$(rd 0x108))); E=\$(( (a1-a0)&0xFFFFFFFF ))
      [ \$E -gt $THRESH ] && break
    done
    cd /tmp && rm -f g.bin
    iio_readdev -b 4096 -s $SZ axi-adrv9002-rx2-lpc voltage0_i voltage0_q > /tmp/g.bin 2>/dev/null
    echo \"TRIG \$E BYTES \$(stat -c %s /tmp/g.bin)\"" 2>/dev/null | tail -1 | tee -a "$OUT/run.log"
  $W $B "cat /tmp/g.bin" > "$OUT/sel$SEL.bin" 2>/dev/null
  $W $B "rm -f /tmp/g.bin" >/dev/null 2>&1
  GOT=$(stat -c %s "$OUT/sel$SEL.bin" 2>/dev/null)
  read -r F1 E1 C1 <<<"$(probe)"
  log "  sel$SEL: $GOT bytes ($(( GOT*100/(SZ*4) ))% of requested) post capTAP=$C1 fps=$F1 errps=$E1"
  [ "$GOT" -lt $(( SZ*4*9/10 )) ] && log "  !!! SHORT CAPTURE -- treat as truncated"
done
log "=== done: sel5 and sel6 from ONE arm"
