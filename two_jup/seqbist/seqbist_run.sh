#!/bin/bash
# seqbist_run.sh -- T2/T3/T4 (happy-bubbling-owl) SEQ-BIST leg runner.
# K=V env, no positional args (launch_rig_unit.sh convention).
#
# BOARD=148|146 (default 148)         resolved via HOSTS.md ips in seqbist_read.py
# MODE=loopback|rf (default loopback) loopback: arm 0x158=1/0x118=0/0x114=0 exactly as
#                                      loopchk_run.sh:31-33; rf: leave the arm to the
#                                      caller, only check 0x114=1
# FILL=1516 (>=100 or refused -- fill<=47 is the deterministic wedge, TGEN_SWEEP.md)
# GAP=0            TGEN gap register, clocks
# SKIP_EVERY=0     0=off; sets tgen gap-word bit27=0 mode, ctrl[31:16]=SKIP_EVERY
# CORRUPT_EVERY=0  0=off; sets tgen gap-word bit27=1 mode, ctrl[31:16]=CORRUPT_EVERY
#                  (SKIP_EVERY and CORRUPT_EVERY both non-zero is an error)
# DUR=600          window seconds
# SINK=none|tgenrx|cyclic (default none)
#                  *** WITHOUT A SINK THE TGEN LEGS MEASURE NOTHING ON SILICON. ***
#                  rx_seq_checker counts valid && ready at the DUT RX byte pins. With no
#                  daemon and no DMA armed, the seam's ready is LOW, the ByteRxFifo never
#                  drains, and both chk_frames AND the legacy rx_seam_checker frames sit at
#                  0 while the demod's 0x104 runs at line rate. loopchk_run.sh:45 already
#                  says it: "The RX DMA must be armed or the DUT byte plane stalls."
#                  Measured here 2026-09-04 00:12 as leg ctrlA att.1 [silicon].
#   tgenrx : 148 only. Set qpsk_traffic_gen_rx2's enable (0x9D410000 bit0) = 1 for the run.
#            qpsk_traffic_gen_rx2.v:114 `assign dut_ready = en_d ? 1'b1 : dma_ready;` --
#            enable HOLDS dut_ready HIGH and consumes+discards the DUT stream at the seam
#            (its header calls it out: "never stall the DUT: sustained drain stall is the
#            #48 wedge trigger"). Its OWN generated frames stall harmlessly against the
#            un-armed DMA. Fabric-only: no DMA, no DDR, no host in the measurement path.
#            Cost of the aliasing: with bit0=1 the injector reads ctrl[15:4] as fill_len,
#            which includes our bits 4/5 (checker en + tgen_mode) -> fill_len = 3 words.
#            Harmless precisely because the DMA side is stalled and nothing consumes them.
#            The RMW preserves bits 3/4/5, and bit0 is cleared again at the end.
#   cyclic : 146 (its image has no traffic_gen_rx2). Arms the RX DMAC as a hardware ring
#            once by devmem -- qpsk_tun.c rx_arm_cyclic():1256-1265 -- so it drains forever
#            with no host loop. This is "DMA as a sink DOWNSTREAM of the measurement": the
#            checker still snoops the DUT pins upstream of it. NOT EXERCISED ON SILICON by
#            task 6 (148 uses tgenrx); addresses are env-overridable.
#   none   : the original behaviour -- REFUSE if bit0 is set.
# DRY=1            default DRY; DRY=0 touches the board over anyssh.sh
# TAG=             optional run-dir tag suffix
#
# Sequence: snapshot registers -> TGEN on -> ~50ms settle (TGEN restarts its own seq
#   at 1 on its enable rise; the checker clear must land AFTER the first frames are
#   flowing or the very first reading shows a spurious dup_or_reorder=1) -> checker
#   enable (clear) -> seqbist_read.py --watch 10 for DUR -> TGEN off -> final read ->
#   post snapshot -> meta.txt + readings.jsonl + run.log in
#   two_jup/comb/runs/<ts>_seqbist_<tag>/
# Exit non-zero if window < 150s, a re-arm happened in-window, or tgen_rx (0x9D410000
#   bit0) is found enabled at preflight (146 lineage: tgen_rx must stay disabled --
#   ctrl bits 4/5 alias qpsk_traffic_gen_rx2's fill_len[1:0] when it's on).
# Prints `SEQBIST_DONE <dir>` last.
set -u
D=$(cd "$(dirname "$0")" && pwd)            # two_jup/seqbist
TJ=$(cd "$D/.." && pwd)                     # two_jup
W=${W:-$TJ/anyssh.sh}
COMB=$TJ/comb

BOARD=${BOARD:-148}
MODE=${MODE:-loopback}
FILL=${FILL:-1516}
GAP=${GAP:-0}
SKIP_EVERY=${SKIP_EVERY:-0}
CORRUPT_EVERY=${CORRUPT_EVERY:-0}
DUR=${DUR:-600}
SINK=${SINK:-none}
DRY=${DRY:-1}
TAG=${TAG:-}
WINDOW_MIN=${WINDOW_MIN:-150}

case "$BOARD" in
  148) BRD=10.0.0.148 ;;
  146) BRD=10.0.0.146 ;;
  *) BRD=$BOARD ;;
esac

# --- TWO-BOARD (stage 3) SUPPORT, added task 8 ------------------------------
# TGEN_BOARD (default = BOARD): the board whose qpsk_traffic_gen is the SOURCE.
#   In a two-board RF leg the generator lives on the TRANSMITTER and the checker
#   (and every counter seqbist_read.py reads) lives on the RECEIVER, so the TGEN
#   register writes must be aimed at a different board from the reads. Defaults to
#   BOARD, so every single-board leg is byte-identical to before.
# TGEN_EXTERNAL=1: do NOT touch the generator at all -- the caller has it running
#   and wants it left alone for the whole leg. This exists because of the R2FINISH
#   ordering finding (bringup_r2r3.sh:~170): on air, flipping the TX source to the
#   byte plane while the byte FIFO is underrunning is demod-hostile, so the caller
#   arms TGEN first, THEN flips 0x158, and must not have that stream interrupted by
#   a TGEN off/on cycle in the middle. With it set, pre_cleanup does not stop TGEN,
#   tgen_on/tgen_off are no-ops, and the leg measures the stream as handed over.
# TXCHK=auto|0|1: read the TX-seam checker at 0x9D420000 on TGEN_BOARD. auto = on
#   only for 148 (the 146 vendh image has nothing at that address -- a devmem read
#   there is not safe to assume); pass TXCHK=1 once 146 runs the seqbist image.
TGEN_BOARD=${TGEN_BOARD:-$BOARD}
case "$TGEN_BOARD" in
  148) TBRD=10.0.0.148 ;;
  146) TBRD=10.0.0.146 ;;
  *) TBRD=$TGEN_BOARD ;;
esac
TGEN_EXTERNAL=${TGEN_EXTERNAL:-0}
TXCHK=${TXCHK:-auto}

if [ "$FILL" -lt 100 ]; then
  echo "SEQBIST_REFUSED: FILL=$FILL < 100 (fill<=47 is the deterministic wedge cliff, TGEN_SWEEP.md; refusing)" >&2
  exit 3
fi
if [ "$SKIP_EVERY" -ne 0 ] && [ "$CORRUPT_EVERY" -ne 0 ]; then
  echo "SEQBIST_REFUSED: SKIP_EVERY and CORRUPT_EVERY cannot both be non-zero (gap bit27 selects one mode)" >&2
  exit 3
fi

TS=$(date +%Y%m%d_%H%M%S)
TAGSUF=${TAG:+_$TAG}
OUT=${OUT:-$COMB/runs/${TS}_seqbist${TAGSUF}}
mkdir -p "$OUT"
log(){ echo "$(date -Is) $*" | tee -a "$OUT/run.log"; }

log "=== seqbist_run.sh: BOARD=$BOARD SINK_PREARMED=${SINK_PREARMED:-0} TGEN_BOARD=$TGEN_BOARD TGEN_EXTERNAL=$TGEN_EXTERNAL MODE=$MODE FILL=$FILL GAP=$GAP SKIP_EVERY=$SKIP_EVERY CORRUPT_EVERY=$CORRUPT_EVERY DUR=$DUR SINK=$SINK DRY=$DRY -> $OUT ==="

DM='DM=$(command -v devmem || echo "busybox devmem")'

REARM_COUNT=0

snap(){ # register snapshot: 0x104 0x108 0x150 0x154 0x15C 0x1B0 via direct_reg_access
  # 0x1B0 = byte_fifo_ovf. It is the SINK WITNESS: if the sink is really fabric-only and
  # the DMA path is dead, this must not move across the run. A rising ovf would mean the
  # ByteRxFifo is overflowing, i.e. the drain is not keeping up and frames are being lost
  # downstream of the checker -- which would contaminate every loss number in the leg.
  if [ "$DRY" = 1 ]; then
    echo "t=$(date +%s.%N) pkts=0 biterr=0 rstcs=0 cfc=0 fx=0 ovf=0"
  else
    $W "$BRD" 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled>/sys/bus/iio/devices/iio:device0/reg_access; rd(){ echo "$1">$DRA;cat $DRA; }
       echo "t=$(date +%s.%N) pkts=$(rd 0x104) biterr=$(rd 0x108) rstcs=$(rd 0x150) cfc=$(rd 0x154) fx=$(rd 0x15C) ovf=$(rd 0x1B0)"' 2>/dev/null
  fi
}

arm_loop(){ # loopback arm, exactly loopchk_run.sh:31-33 (0x158=1,0x118=0,0x114=0)
  if [ "$DRY" = 1 ]; then
    log "[dry] $W $BRD arm_loop (0x158=1 0x118=0 0x114=0, double-tap)"
  else
    $W "$BRD" 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
      echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
      TXD=$(for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name 2>/dev/null)" = axi-adrv9002-tx-lpc ] && echo ${d##*/}; done)
      T=/sys/kernel/debug/iio/$TXD/direct_reg_access
      for k in 1 2; do
        echo "0x000 0x1">$DRA; sleep 0.5; echo "0x000 0x0">$DRA
        echo "0x158 0x1">$DRA; echo "0x118 0x0">$DRA; echo "0x114 0x0">$DRA
        echo "0x418 0x2">$T; echo "0x458 0x2">$T; echo "0x044 0x1">$T
        echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA; [ $k = 1 ] && sleep 3
      done' 2>/dev/null
    REARM_COUNT=$((REARM_COUNT+1))
  fi
}

check_rf_armed(){ # rf mode: only check 0x114=1, arm left to caller
  if [ "$DRY" = 1 ]; then
    log "[dry] $W $BRD check 0x114==1 (rf arm left to caller)"
  else
    # FALSE GATE REMOVED (task 8, 2026-09-04, on silicon). 0x114 -- like 0x158 and 0x118 --
    # is WRITE-ONLY in the HDL-Coder AXI decoder (BIST_SEQ_SURVEY.md:29,
    # TxRxCompo_ip_addr_decoder.v:602-604 returns const_0), so this read returns 0 no matter
    # what was written. Task 6 corrected exactly this mistake for 0x158 ("verify the arm by
    # EFFECT, not by read-back") but left the same read-back refusal here for 0x114. It cost
    # a leg: t8-fwd45k, whose bring-up gate had just PASSED on air at 0x124=1242.8 f/s with
    # chk_frames 1241.6 (dev 0.094 %), was refused two seconds later on "0x114 read 0".
    # The arm is verified downstream by verify_arm_by_effect, which is the real test.
    v=$($W "$BRD" "$DM; DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo 0x114 > \$DRA; cat \$DRA" 2>/dev/null)
    v=$((v))
    log "MODE=rf: 0x114 read back $v (write-only register -- reported, NOT gated; the arm is verified by effect below)"
  fi
}

checker_clear(){ # tgen_rx ctrl bit4 = checker enable/clear pulse
  # ORDER (fix round 2): TGEN restarts its own seq at 1 on its enable rise. If the
  # checker's clear (en low->high) lands before or concurrently with TGEN's first
  # frames, the checker's internal last_seq is still 0 and the first real frame
  # (seq=1) reads as dup_or_reorder rather than in-order. Caller MUST call this
  # AFTER tgen_on + a settle delay -- see the ~50ms sleep in the main sequence below.
  # RMW CONTRACT (fix round 2): every write to 0x9D410000 must read-modify-write,
  # preserving bit0 (tgen_rx enable -- must stay 0, see check_tgen_rx_disabled)
  # and bit5 (tgen_mode) as well as any other live bits; a plain constant write
  # would clear en and silently zero every counter mid-run.
  if [ "$DRY" = 1 ]; then
    # fabricate a plausible original word (bit5 tgen_mode=1, bit0=0, bit4=0) and
    # walk the RMW explicitly so the bit-preservation is visible in the log.
    local orig=0x00000020
    local cleared=$(( orig & ~16 ))
    local set=$(( orig | 16 ))
    log "[dry] $W $BRD checker clear RMW: read ctrl=$(printf '0x%08X' "$orig") -> clear bit4 -> write $(printf '0x%08X' "$cleared") -> set bit4 -> write $(printf '0x%08X' "$set") (bit0=0 preserved, bit5=1 preserved, AFTER tgen_on+settle)"
  else
    # force bit4 LOW first so the rising edge (= clear) is guaranteed even if a prior run
    # left it stuck high (review task-4-review.md), then leave the checker ENABLED (bit4=1)
    # for the whole run -- the contract says en = enable, clear on its rising edge.
    $W "$BRD" "$DM; C=\$(\$DM 0x9D410000); \$DM 0x9D410000 32 \$(( C & ~16 )); sleep 0.05; \$DM 0x9D410000 32 \$(( C | 16 ))" 2>/dev/null
  fi
}

check_tgen_rx_disabled(){ # SINK=none only: tgen_rx (0x9D410000 bit0) must stay OFF --
  # on 148 its ctrl bits 4/5 alias qpsk_traffic_gen_rx2's fill_len[1:0] when tgen_rx is
  # enabled, corrupting the checker freeze/checker-enable bits this tool relies on.
  if [ "$DRY" = 1 ]; then
    log "[dry] $W $BRD preflight: check tgen_rx enable (0x9D410000 bit0) == 0"
  else
    v=$($W "$BRD" "$DM; \$DM 0x9D410000" 2>/dev/null)
    v=$((v))
    if [ $(( v & 1 )) -ne 0 ]; then
      log "SEQBIST_REFUSED: tgen_rx enable (0x9D410000 bit0) is set; ctrl[5:4] would alias fill_len, corrupting freeze/checker-enable. Disable tgen_rx before running, or run with SINK=tgenrx which owns that bit deliberately."
      echo "SEQBIST_REFUSED: tgen_rx enable (0x9D410000 bit0) is set" >&2
      echo "leg=seqbist board=$BRD mode=$MODE dur=$DUR dry=$DRY window_s=0" > "$OUT/meta.txt"
      exit 5
    fi
  fi
}

SINK_ARMED=0
# --- SINK=cyclic register map (qpsk_tun.c:104-117 + qpsk_hw.h:50,57) ---------
CYC_DMA_BASE=${CYC_DMA_BASE:-0x9D200000}     # QPSK_RX_DMA_BASE (Jupiter)
CYC_DEST=${CYC_DEST:-0x7FE40000}             # QPSK_DMA_BUF_BASE 0x7FE00000 + TUN_RX 0x40000
CYC_RING_BYTES=${CYC_RING_BYTES:-98304}      # 64 x 1536 B
# SINK_PREARMED=1 (task 8): the CALLER has already armed the drain and owns it for the
# whole leg -- arm nothing, but still register it so the EXIT trap disarms it. This exists
# for SINK=cyclic, where re-arming means CONTROL=0 then CONTROL=1, i.e. a full DMAC
# teardown and re-submit: on a path with no silicon history a ring that does not come back
# up drops dut_ready, freezes chk_frames and lands the leg in verify_arm_by_effect's
# NEEDS_ARM exit -- after the bring-up gate has already been spent. (For SINK=tgenrx the
# re-arm is an idempotent bit-set and harmless; the guard covers both for symmetry.)
SINK_PREARMED=${SINK_PREARMED:-0}
sink_arm(){
  if [ "$SINK_PREARMED" = 1 ] && [ "$SINK" != none ]; then
    log "SINK=$SINK: PRE-ARMED BY THE CALLER (SINK_PREARMED=1) -- not touching the drain; it will still be disarmed on exit"
    SINK_ARMED=1
    return 0
  fi
  case "$SINK" in
    none)
      check_tgen_rx_disabled
      log "SINK=none: no drain armed. On silicon with no daemon this means the DUT byte plane STALLS and every counter stays 0 -- use SINK=tgenrx on 148."
      ;;
    tgenrx)
      if [ "$BOARD" != 148 ]; then
        log "SEQBIST_REFUSED: SINK=tgenrx is 148-only (146's image has no qpsk_traffic_gen_rx2)"
        echo "SEQBIST_REFUSED: SINK=tgenrx is 148-only" >&2; exit 5
      fi
      if [ "$DRY" = 1 ]; then
        local orig=0x00000030
        log "[dry] SINK=tgenrx RMW: read ctrl=$(printf '0x%08X' "$orig") -> set bit0 -> write $(printf '0x%08X' "$(( orig | 1 ))") (bits 3/4/5 preserved; injector fill_len then reads ctrl[15:4]=3 words, harmless -- its DMA is un-armed)"
      else
        C=$($W "$BRD" "$DM; C=\$(\$DM 0x9D410000); \$DM 0x9D410000 32 \$(( C | 1 )); echo \"pre=\$C post=\$(\$DM 0x9D410000)\"" 2>/dev/null | tr -d '\r')
        log "SINK=tgenrx armed: $C  (dut_ready now held HIGH at the RX seam; DUT stream consumed+discarded, fabric-only)"
      fi
      SINK_ARMED=1
      ;;
    cyclic)
      # DMA as a sink DOWNSTREAM of the measurement: the checker snoops the DUT pins
      # upstream of the DMAC, so the loss numbers stay fabric-only; the ring only keeps
      # the byte plane draining. One-shot register sequence, no host loop.
      if [ "$DRY" = 1 ]; then
        log "[dry] SINK=cyclic: devmem $CYC_DMA_BASE+0x400=0 -> +0x400=1 -> +0x410=$CYC_DEST -> +0x418=$((CYC_RING_BYTES-1)) -> +0x40C=1 (cyclic) -> +0x408=1 (submit)"
      else
        C=$($W "$BRD" "$DM; B=$CYC_DMA_BASE
          \$DM \$((B+0x400)) 32 0; \$DM \$((B+0x400)) 32 1
          \$DM \$((B+0x410)) 32 $CYC_DEST; \$DM \$((B+0x418)) 32 $((CYC_RING_BYTES-1))
          \$DM \$((B+0x40C)) 32 1; \$DM \$((B+0x408)) 32 1
          echo \"ctrl=\$(\$DM \$((B+0x400))) flags=\$(\$DM \$((B+0x40C)))\"" 2>/dev/null | tr -d '\r')
        log "SINK=cyclic armed: $C (NOT silicon-exercised by task 6)"
      fi
      SINK_ARMED=1
      ;;
    *) echo "SEQBIST_REFUSED: unknown SINK=$SINK (none|tgenrx|cyclic)" >&2; exit 3 ;;
  esac
}
sink_disarm(){
  [ "$SINK_ARMED" = 1 ] || return 0
  SINK_ARMED=0
  case "$SINK" in
    tgenrx)
      if [ "$DRY" = 1 ]; then log "[dry] SINK=tgenrx disarm: RMW clear bit0 (bits 3/4/5 preserved)"
      else
        C=$($W "$BRD" "$DM; C=\$(\$DM 0x9D410000); \$DM 0x9D410000 32 \$(( C & ~1 )); echo \$(\$DM 0x9D410000)" 2>/dev/null | tr -d '\r')
        log "SINK=tgenrx disarmed: ctrl=$C (bit0 back to 0)"
      fi ;;
    cyclic)
      if [ "$DRY" = 1 ]; then log "[dry] SINK=cyclic disarm: devmem $CYC_DMA_BASE+0x400=0"
      else
        $W "$BRD" "$DM; \$DM \$(($CYC_DMA_BASE+0x400)) 32 0" 2>/dev/null
        log "SINK=cyclic disarmed (DMAC CONTROL=0)"
      fi ;;
  esac
}
trap 'sink_disarm' EXIT INT TERM

tgen_on(){
  # Interface contract (progress.md): ctrl@0x9D400000 bit0 enable, [15:4] fill,
  # [31:16] = skip_every OR corrupt_every (the N); gap@0x9D400008 [26:0] gap clks,
  # bit27 selects which meaning N has (0=skip_every, 1=corrupt_every).
  local n=0 mode=0
  if [ "$SKIP_EVERY" -ne 0 ]; then
    n=$SKIP_EVERY; mode=0
  elif [ "$CORRUPT_EVERY" -ne 0 ]; then
    n=$CORRUPT_EVERY; mode=1
  fi
  local gapclks=$(( GAP & 0x7FFFFFF ))
  local gapword=$(( gapclks | (mode << 27) ))
  local ctrlword=$(( (n << 16) | (FILL << 4) | 1 ))
  log "TGEN_WORDS ctrl=$(printf '0x%08X' "$ctrlword") gap=$(printf '0x%08X' "$gapword") fill=$FILL n=$n mode=$mode skip_every=$SKIP_EVERY corrupt_every=$CORRUPT_EVERY"
  if [ "$TGEN_EXTERNAL" = 1 ]; then
    log "TGEN_EXTERNAL=1: generator on $TBRD left exactly as the caller armed it (no ctrl/gap write, no restart of the byte stream)"
    return 0
  fi
  if [ "$DRY" = 1 ]; then
    log "[dry] $W $TBRD TGEN on: gap@0x9D400008=$gapword ctrl@0x9D400000=$ctrlword"
  else
    $W "$TBRD" "$DM; \$DM 0x9D400008 32 $gapword; \$DM 0x9D400000 32 $ctrlword; echo TGEN ctrl=\$(\$DM 0x9D400000) gap=\$(\$DM 0x9D400008)" 2>/dev/null | tee -a "$OUT/run.log"
  fi
}

tgen_off(){
  if [ "$TGEN_EXTERNAL" = 1 ]; then
    log "TGEN_EXTERNAL=1: leaving the generator on $TBRD running (caller owns it)"
    return 0
  fi
  if [ "$DRY" = 1 ]; then
    log "[dry] $W $TBRD TGEN off (ctrl@0x9D400000=0)"
  else
    $W "$TBRD" "$DM; \$DM 0x9D400000 32 0" 2>/dev/null
  fi
}

pre_cleanup(){
  # tgen_rx ctrl write is RMW (captures C, clears only bit3/freeze) -- preserves
  # bit0 (tgen_rx enable, must stay 0) and bit5 (tgen_mode); see the RMW CONTRACT
  # note in checker_clear().
  if [ "$DRY" = 1 ]; then
    log "[dry] $W $BRD tgen_rx ctrl RMW clears only bit3/freeze (bit0/bit5 preserved)"
    [ "$TGEN_EXTERNAL" = 1 ] || log "[dry] $W $TBRD TGEN ctrl=0 (plain write)"
  else
    $W "$BRD" "$DM; C=\$(\$DM 0x9D410000); \$DM 0x9D410000 32 \$(( C & ~8 ))" 2>/dev/null
    [ "$TGEN_EXTERNAL" = 1 ] || $W "$TBRD" "$DM; \$DM 0x9D400000 32 0" 2>/dev/null
  fi
}

# ---- sequence -----------------------------------------------------------
pre_cleanup

if [ "$MODE" = loopback ]; then
  arm_loop
elif [ "$MODE" = rf ]; then
  check_rf_armed
else
  echo "SEQBIST_REFUSED: unknown MODE=$MODE (loopback|rf)" >&2
  exit 3
fi
REARM_PRE=$REARM_COUNT   # the pre-window arm is NOT a re-arm (loopfloor_go.sh convention)
REARM_COUNT=0

sink_arm

txchk(){
  # tx_seam_checker counters on txchk_gpio @0x9D420000 (BIST_SEQ_SURVEY.md:14):
  #   ch1 @+0x0 = bit_errors, ch2 @+0x8 = frames_checked.
  # It snoops the DUT TX byte pins POST-mux and self-arms on the TGEN header, so it
  # says whether the frames left the TX byte plane intact. Read pre/post per leg:
  # frames_checked == TGEN emitted and bit_errors == 0 localises any loss DOWNSTREAM
  # of the TX pins (modulator / demod / deframer) rather than in the generator.
  # 148-only: 0x9D420000 is unused on the 146 vendh image (task-2 report).
  # Reads the TRANSMITTER's TX seam (TGEN_BOARD), which is where the generator is.
  local want=$TXCHK
  [ "$want" = auto ] && { [ "$TGEN_BOARD" = 148 ] && want=1 || want=0; }
  if [ "$DRY" = 1 ]; then echo "tx_bit_errors=0 tx_frames_checked=0"
  elif [ "$want" != 1 ]; then echo "tx_bit_errors=NA tx_frames_checked=NA (TXCHK=$TXCHK, tgen_board=$TGEN_BOARD)"
  else
    $W "$TBRD" "$DM; echo \"tx_bit_errors=\$((\$(\$DM 0x9D420000))) tx_frames_checked=\$((\$(\$DM 0x9D420008)))\"" 2>/dev/null | tr -d '\r'
  fi
}

SNAP_PRE=$(snap); echo "$SNAP_PRE" > "$OUT/regs_pre.txt"
TXCHK_PRE=$(txchk); log "TXCHK_PRE $TXCHK_PRE"

tgen_on
if [ "$DRY" = 1 ]; then
  log "[dry] settle 50ms (TGEN's own seq restarts at 1 on enable rise; checker clear must follow)"
else
  sleep 0.05
fi
checker_clear

READ=$D/seqbist_read.py

verify_arm_by_effect(){
  # VERIFY THE ARM BY EFFECT, NOT BY READ-BACK (coordinator ruling 2026-09-04).
  #
  # The previous version of this check compared read-backs of 0x158/0x114/0x118 and
  # refused ctrlA-r2 on "arm did not stick". That was a FALSE GATE: those three are
  # WRITE-ONLY in the HDL-Coder AXI decoder -- they appear in the WRITE-taken list and
  # NOT in the READ-taken list (BIST_SEQ_SURVEY.md:29; TxRxCompo_ip_addr_decoder.v
  # :602-604 "anything else returns const_0"), so a direct_reg_access read of them
  # returns 0 no matter what was written. Measured directly here (unit t6-probe158,
  # 2026-09-04 00:2x) [silicon]: 0x158 read 0x0 immediately after writing 0x1, again
  # after 1 s, again after a 0x110 pulse, again after a full arm sequence, and again
  # after writing 0x0 -- five reads, one value, while 0x104 advanced at 1247-1248 f/s
  # throughout. (0x10C, used as the probe's "control", is ALSO write-only and likewise
  # read 0 -- the real proof the read path works is 0x104 counting.)
  #
  # So the arm is verified by its EFFECT instead: with the sink armed and TGEN running,
  # the checker must actually see frames. chk_frames advancing in step with 0x104 is
  # the only statement that matters, and it is exactly what a bad arm, a dead sink or a
  # stalled seam would each break.
  #
  # An ssh failure here is "unreachable", never a measurement: seqbist_read.py raises
  # rather than returning zeros, and 0x104 (READ-taken, :29) is the readable witness.
  [ "$DRY" = 1 ] && { log "[dry] verify_arm_by_effect: up to 3 samples; require chk_frames AND 0x104 to advance"; return 0; }
  local i=0 prev cur d104 dchk
  prev=$(python3 "$READ" "$BOARD" 2>>"$OUT/run.log") || {
    log "SEQBIST_UNINFORMATIVE: seqbist_read.py failed (board unreachable) at the effect gate"
    echo "leg=seqbist board=$BRD mode=$MODE dur=$DUR dry=$DRY window_s=0 arm_verified_by_effect=0 reason=unreachable" > "$OUT/meta.txt"
    echo "SEQBIST_UNINFORMATIVE: unreachable at effect gate" >&2; exit 6; }
  while [ "$i" -lt 3 ]; do
    sleep 5
    cur=$(python3 "$READ" "$BOARD" 2>>"$OUT/run.log") || {
      log "SEQBIST_UNINFORMATIVE: seqbist_read.py failed (board unreachable) at the effect gate"
      echo "leg=seqbist board=$BRD mode=$MODE dur=$DUR dry=$DRY window_s=0 arm_verified_by_effect=0 reason=unreachable" > "$OUT/meta.txt"
      echo "SEQBIST_UNINFORMATIVE: unreachable at effect gate" >&2; exit 6; }
    set -- $(python3 -c '
import json, sys
a, b = json.loads(sys.argv[1]), json.loads(sys.argv[2])
print(b["reg_0x104"] - a["reg_0x104"], b["chk_frames"] - a["chk_frames"])' "$prev" "$cur")
    d104=$1; dchk=$2
    i=$((i+1))
    log "ARM_EFFECT sample $i: d0x104=$d104 d_chk_frames=$dchk"
    if [ "$d104" -gt 0 ] && [ "$dchk" -gt 0 ]; then
      log "ARM_VERIFIED_BY_EFFECT (checker is seeing frames; arm + sink + seam all live)"
      return 0
    fi
    prev=$cur
  done
  log "SEQBIST_UNINFORMATIVE: after 3 samples the checker never advanced (last d0x104=$d104 d_chk_frames=$dchk)."
  if [ "${d104:-0}" -gt 0 ] && [ "${dchk:-0}" -le 0 ]; then
    log "  NEEDS_ARM (most likely): the demod IS running (d0x104=$d104) but the RX byte seam"
    log "  delivered nothing. MODE=loopback here only writes 0x158/0x118/0x114 (the"
    log "  loopchk_run.sh:31-33 register triple) -- that is NOT a full arm. It has no modem"
    log "  enable (0x004 / the 0x000 reset pulse), no byte-plane re-arm (0x9D300000 bit0) and"
    log "  no rstCS. Earlier legs only worked because they INHERITED the armed mode-1 state"
    log "  left behind by the flash chain's arm148_mode1.sh gate."
    log "  capture_r3.sh's quiesce zeroes 0x9D000000 and 0x9D000114 (modem enable + RX input"
    log "  select) and deletes tun0, so ANY SEQ-BIST leg that follows a daemon leg or a"
    log "  quiesce starts from an unarmed board and lands exactly here."
    log "  FIX: run two_jup/arm148_mode1.sh as its own unit FIRST (it leaves 148 in mode-1"
    log "  loopback decoding ROM at ~1248 f/s with capTAP golden), then re-run this leg."
    echo "leg=seqbist board=$BRD mode=$MODE dur=$DUR dry=$DRY window_s=0 arm_verified_by_effect=0 diagnosis=NEEDS_ARM d104=$d104 dchk=$dchk" > "$OUT/meta.txt"
    echo "SEQBIST_NEEDS_ARM: demod running (d0x104=$d104) but seam delivered nothing -- run arm148_mode1.sh first" >&2
    exit 6
  fi
  if [ "${d104:-0}" -le 0 ]; then
    log "  MODEM_DEAD: 0x104 is not advancing at all -- the modem is not producing frames."
    log "  This is an arm/profile problem, not a checker or sink problem."
  fi
  log "  NOT re-arming (no retry loops); report and stop."
  echo "leg=seqbist board=$BRD mode=$MODE dur=$DUR dry=$DRY window_s=0 arm_verified_by_effect=0 d104=$d104 dchk=$dchk" > "$OUT/meta.txt"
  echo "SEQBIST_UNINFORMATIVE: checker never advanced" >&2; exit 6
}
verify_arm_by_effect
READINGS=$OUT/readings.jsonl
: > "$READINGS"

WATCH_S=10
if [ "$DRY" = 1 ]; then
  DRY_ENV="--dry --skip-every $SKIP_EVERY --corrupt-every $CORRUPT_EVERY"
else
  DRY_ENV=""
fi

t0=$(date +%s)
timeout "$DUR" python3 "$READ" "$BOARD" --watch "$WATCH_S" $DRY_ENV >> "$READINGS" 2>>"$OUT/run.log"
t1=$(date +%s)
WINDOW_S=$((t1 - t0))

tgen_off

FINAL=$(python3 "$READ" "$BOARD" $DRY_ENV 2>>"$OUT/run.log")
echo "$FINAL" > "$OUT/final_read.json"

SNAP_POST=$(snap); echo "$SNAP_POST" > "$OUT/regs_post.txt"
TXCHK_POST=$(txchk); log "TXCHK_POST $TXCHK_POST"
TXCHK_DELTA=$(python3 - "$TXCHK_PRE" "$TXCHK_POST" <<'PY'
import re, sys
def kv(t): return {k: v for k, v in re.findall(r"(\w+)=(\S+)", t)}
a, b = kv(sys.argv[1]), kv(sys.argv[2])
out = []
for k in ("tx_bit_errors", "tx_frames_checked"):
    va, vb = a.get(k), b.get(k)
    try:
        out.append(f"d_{k}={int(vb) - int(va)}")
    except (TypeError, ValueError):
        out.append(f"d_{k}=NA")
print(" ".join(out))
PY
)
log "TXCHK_DELTA $TXCHK_DELTA"

N_READINGS=$(wc -l < "$READINGS" 2>/dev/null || echo 0)

RATE_FPS=$(python3 - "$READINGS" "$WINDOW_S" <<'PY'
import json, sys
path, window_s = sys.argv[1], float(sys.argv[2])
rows = []
with open(path) as f:
    for ln in f:
        ln = ln.strip()
        if ln:
            rows.append(json.loads(ln))
if len(rows) >= 2 and window_s > 0:
    print(f"{(rows[-1]['chk_frames'] - rows[0]['chk_frames']) / window_s:.1f}")
else:
    print("0.0")
PY
)

IMG_MD5=$([ "$DRY" = 1 ] && echo "dry-no-board" || $W "$BRD" 'md5sum /boot/BOOT.BIN 2>/dev/null | cut -c1-32' 2>/dev/null)

# ---- SINK WITNESS (coordinator ruling 2026-09-04) --------------------------
# Two things must hold for a SINK=tgenrx leg to be fabric-only and trustworthy:
#   acc_beats (slot 7, qpsk_traffic_gen_rx2's own accumulated DMA beats) stays 0
#     -> the injector generated nothing into a live DMA; it only drained the DUT.
#   0x1B0 byte_fifo_ovf constant across the run
#     -> the ByteRxFifo never overflowed, so nothing was lost downstream of the checker.
SINK_WIT=$(python3 - "$READINGS" "$OUT/regs_pre.txt" "$OUT/regs_post.txt" <<'PY'
import json, re, sys
rows = []
try:
    for ln in open(sys.argv[1]):
        ln = ln.strip()
        if ln: rows.append(json.loads(ln))
except OSError:
    pass
def ovf(path):
    try:
        m = re.search(r"ovf=(\d+)", open(path).read())
        return int(m.group(1)) if m else -1
    except OSError:
        return -1
o0, o1 = ovf(sys.argv[2]), ovf(sys.argv[3])
if rows:
    ab = rows[-1]["acc_beats"] - rows[0]["acc_beats"]
    abs_last = rows[-1]["acc_beats"]
else:
    ab, abs_last = -1, -1
ok = (ab == 0 and abs_last == 0 and o0 >= 0 and o0 == o1)
print(f"sink_acc_beats_delta={ab} sink_acc_beats_last={abs_last} ovf_pre={o0} ovf_post={o1} sink_witness_ok={int(ok)}")
PY
)
{
  echo "leg=seqbist board=$BRD mode=$MODE dur=$DUR window_s=$WINDOW_S dry=$DRY rate_fps=$RATE_FPS"
  echo "fill=$FILL gap=$GAP skip_every=$SKIP_EVERY corrupt_every=$CORRUPT_EVERY"
  echo "n_readings=$N_READINGS rearms_in_window=$REARM_COUNT rearm_pre_window=$REARM_PRE arm_verified_by_effect=1"
  echo "sink=$SINK $SINK_WIT"
  echo "txchk_pre=\"$TXCHK_PRE\" txchk_post=\"$TXCHK_POST\" $TXCHK_DELTA"
  echo "image_md5=$IMG_MD5"
  echo "ts=$(date -Is)"
} > "$OUT/meta.txt"
log "SINK_WITNESS $SINK_WIT"

RC=0
if [ "$WINDOW_S" -lt "$WINDOW_MIN" ]; then
  log "UNINFORMATIVE: window_s=$WINDOW_S < $WINDOW_MIN"
  RC=1
fi
if [ "$REARM_COUNT" -gt 0 ]; then
  log "UNINFORMATIVE: $REARM_COUNT re-arm(s) in-window"
  RC=1
fi

log "seqbist_run.sh done: window_s=$WINDOW_S n_readings=$N_READINGS rc=$RC"
echo "SEQBIST_DONE $OUT"
exit $RC
