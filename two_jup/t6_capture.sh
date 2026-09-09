#!/bin/bash
# =============================================================================
# t6_capture.sh -- BURST-TRIGGERED raw DDR capture (Task 6).
#
# Why triggered, not blind: a 200-frame capture is ~0.157 s of data, bursts last
# ~6 s and recur every ~121 s -- a ~5 % duty cycle. Blind captures land in a
# burst about 1 time in 20, so a small blind run returns a clean, confident,
# EMPTY result. Instead we trigger on an instrument already trusted: 0x108 bit
# errors, ~51/s quiet against 10k-70k/s in a burst (§32). Bursts last ~6 s, so
# one trigger yields several captures.
#
# CHANNEL NAMING, measured on silicon 2026-08-31 22:33: the RX2 iio device
# exposes only voltage0_i/voltage0_q -- TWO scan elements, not four. The DMA
# stream nonetheless carries all FOUR 16-bit words per beat; de-interleaving by
# 4 recovers I, Q and both markers, verified by period-4 analysis (phases 2 and
# 3 take exactly two values, 0x0000 and 0x7FFF). Asking iio_readdev for
# voltage2/voltage3 fails; ask for the two it knows and read the stream as 4.
#
# Captures nothing until the four-part positive control (ddrcap_pc.py) passes.
# Scoring is t6_score.py -- per-frame displacement, not per-second.
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd)
W=$D/anyssh.sh
B=${B:-10.0.0.148}
NBURST=${NBURST:-12}          # how many burst-triggered captures to collect
NQUIET=${NQUIET:-4}           # quiet controls, for contrast
NSAMP=${NSAMP:-262144}        # words per capture
THRESH=${THRESH:-5000}        # errs/s above which a second counts as a burst
OUT=${OUT:-$D/t6/$(date +%Y%m%d_%H%M%S)}
mkdir -p "$OUT"
log(){ echo "$(date +%T) $*" | tee -a "$OUT/run.log"; }

log "=== t6_capture on $B -> $OUT (need $NBURST burst + $NQUIET quiet captures)"

# Discover the RX2 capture device at RUNTIME and fail loudly. Vendors rename
# these between BSPs; a hardcoded iio:deviceN is how a capture silently reads
# the wrong stream.
DEV=$($W $B 'for d in /sys/bus/iio/devices/iio:device*; do
  n=$(cat $d/name 2>/dev/null)
  case "$n" in *rx2*|*rx-2*|*lpc2*) echo "$n"; ;; esac
done | head -1' 2>/dev/null | tr -d " \r\n")
if [ -z "$DEV" ]; then
  log "!!! ABORT: no RX2 capture device found. Discovered devices:"
  $W $B 'for d in /sys/bus/iio/devices/iio:device*; do echo "  $d $(cat $d/name 2>/dev/null)"; done' 2>/dev/null | tee -a "$OUT/run.log"
  log "!!! Not guessing a device name -- a capture from the wrong stream looks like data."
  exit 3
fi
log "  RX2 capture device: $DEV"

# SET AND VERIFY THE SELECTOR HERE, not in the caller. On 2026-08-31 a campaign
# ran with the selector left at 0 from a previous step: 0 is the SAMPLE domain
# (~49,349 beats/frame), so every 32,768-beat capture held LESS THAN ONE FRAME
# and all ten were unscoreable. The register 0x10C is WRITE-ONLY -- it always
# reads back 0x0 -- so it cannot be verified directly; verify by EFFECT, via the
# DBGCAP digest at 0x20C, which the low nibble selects.
#   0x10C = (ddrcap_sel << 16) | dbgcap_tap
SEL=${SEL:-6}            # 6 = QPSKConstellationPoints, symbol domain
DTAP=${DTAP:-3}          # 3 = constellation, golden 0xBCF94856
GOLD=${GOLD:-0xBCF94856}
MUXVAL=$(printf '0x%X' $(( (SEL << 16) | DTAP )))
GOT=$($W $B "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
  echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
  echo '0x10C $MUXVAL' > \$DRA; sleep 2
  echo '0x20C' > \$DRA; cat \$DRA" 2>/dev/null | tr -d ' \r\n' | tr 'a-f' 'A-F')
WANT=$(printf %s "$GOLD" | sed -E 's/^0[xX]//' | tr 'a-f' 'A-F')
GOTN=$(printf %s "$GOT" | sed -E 's/^0[xX]//')
log "  selector: 0x10C=$MUXVAL (ddrcap sel=$SEL, dbgcap tap=$DTAP); 0x20C=[$GOTN] want [$WANT]"
if [ "$GOTN" != "$WANT" ]; then
  log "!!! ABORT: DBGCAP digest does not match tap $DTAP golden -- the mux write did not take,"
  log "!!! or the link is not locked. Capturing now would record the wrong tap. Nothing captured."
  exit 4
fi

nb=0; nq=0; i=0
while [ $nb -lt $NBURST ] || [ $nq -lt $NQUIET ]; do
  i=$((i+1))
  [ $i -gt 4000 ] && { log "!!! giving up after $i polls (nb=$nb nq=$nq)"; break; }
  E=$($W $B "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
    echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
    rd(){ echo \"\$1\">\$DRA; cat \$DRA; }
    e0=\$((\$(rd 0x108))); sleep 1; e1=\$((\$(rd 0x108))); echo \$(( (e1-e0)&0xFFFFFFFF ))" 2>/dev/null | tr -d " \r\n")
  [ -z "$E" ] && continue
  if [ "$E" -gt "$THRESH" ] && [ $nb -lt $NBURST ]; then
    kind=burst; nb=$((nb+1)); n=$nb
  elif [ "$E" -le 200 ] && [ $nq -lt $NQUIET ]; then
    kind=quiet; nq=$((nq+1)); n=$nq
  else
    continue
  fi
  f="$OUT/${kind}_$(printf %02d $n)_err${E}.bin"
  $W $B "cd /tmp && iio_readdev -b 4096 -s $NSAMP $DEV voltage0_i voltage0_q > /tmp/t6cap.bin 2>/tmp/t6cap.err; echo \$?" >/dev/null 2>&1
  $W $B 'cat /tmp/t6cap.bin' > "$f" 2>/dev/null
  sz=$(stat -c %s "$f" 2>/dev/null || echo 0)
  log "  [$kind $n/$([ $kind = burst ] && echo $NBURST || echo $NQUIET)] errs/s=$E bytes=$sz -> $(basename "$f")"
  [ "$sz" -lt 1024 ] && log "    !!! capture is $sz bytes -- readback produced nothing, check $DEV"
done

log "=== collected: $nb burst, $nq quiet"
log "=== NOTHING here may be interpreted until ddrcap_pc.py passes on these buffers."
