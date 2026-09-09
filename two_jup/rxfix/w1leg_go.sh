#!/bin/bash
# w1leg_go.sh -- RXFIX Task 10: drive the RXFIX_W1 instrument on 148.
#
#   MODE=ctrl : Step 2, the positive controls and nulls for EVERY new tap, in 148
#               digital loopback (arm148_mode1.sh, SINK=tgenrx). Three reads 10 s
#               apart, a 10 s FREEZE-HOLD read, ONE re-arm, three more reads.
#   MODE=air  : Step 3, the witnessed forward air leg (146 TX -> 148 RX) via
#               legrun_go.sh LEG=A, with the W1 reader and the SEQ-BIST checker
#               read inside the scored window.
#
# ---------------------------------------------------------------------------
# WHY THE IN-WINDOW READER IS A SEQUENTIAL LOOP AND NOT TWO BACKGROUND READERS
# ---------------------------------------------------------------------------
# slackleg_go.sh backgrounds stage3h_reader.sh alongside the leg, and that is safe
# THERE because stage3h_reader.sh is the only direct_reg_access user in the window.
# It is NOT safe here.  The modem register window is read through a SINGLE shared
# address-select register: `echo <addr> > $DRA; cat $DRA`
# (TxRxCompo_ip_addr_decoder.v:199 address_select_level1 = addr_read[7:0]).  Two
# concurrent ssh sessions each doing write-then-read will interleave, and each one
# then `cat`s the OTHER's selected address -- silently, with no error and a
# perfectly plausible value.  w1_read.sh sweeps 16-18 addresses per reading and
# seqbist_read.py reads 0x104/0x124 per sample; at a common 10 s cadence they WILL
# collide.  A corrupted W1 sweep is the one thing this task cannot afford, because
# the whole point is deciding whether 0x214 returns witA or garbage.
#
# So the two readers run one after the other inside ONE loop: w1_read.sh (one ssh
# round trip) then seqbist_read.py (one ssh round trip), then sleep to the cadence.
# They are never in flight at the same time.  A second benefit: the checker sample
# and the W1 sweep are paired within the same iteration, which is what P3's
# "checker gap events per 10 s vs pop_on_empty delta" comparison needs.
# (freeze_effective would catch most W1-side corruption after the fact -- a race
# would make the two frozen sweeps differ -- but "detectable" is not "avoided".)
#
# ---------------------------------------------------------------------------
# FIXCTL_BASE
# ---------------------------------------------------------------------------
# 0x208 is WRITE-ONLY and a freeze write sets the WHOLE 32-bit fixctl word, so
# w1_read.sh must be told what is currently armed (W1_REGMAP.md sec 2).  This task
# runs FIXCTL_BASE=0x0 and states it, on this evidence:
#   * arm148_mode1.sh:~58 writes '0x208 0x0' as part of every arm, so after any arm
#     through that path fixctl IS 0 -- verified by construction, not assumed;
#   * bringup_r2r3.sh and capture_r3.sh contain NO 0x208 write at all (grepped), so
#     an air leg inherits fixctl from the arm / from FPGA reset, both of which are 0;
#   * w1_read.sh's own unfreeze writes FIXCTL_BASE back after every reading, so from
#     the first reading onward fixctl=0x0 holds by construction.
# Consequence of FIXCTL_BASE=0x0: enSlack (bit 3) = 0 and the TXCAP/DEMODCAP read
# muxes (bits 12/13) = 0 for the whole run.  That is the intended run state (bit 12/13
# = 0 keeps 0x20C on the DBGCAP source that arm148_mode1.sh's golden capTAP expects).
#
# K=V: MODE=ctrl|air (required)  DRY=1(default)  DUR=600  OUT=<dir>  TAG=<tag>
#      FIXCTL_BASE=0x0  PERIOD=10  EXP=<expected image md5-12>  RATE_GATE=900
#      LEG=A|B (default A)  BOARD=148|146 (default 148)  RSSI=0|1 (default 0)
#      LEG and BOARD must name the same side: LEG=A -> BOARD=148, LEG=B -> BOARD=146
#      (the script READS the RX board). RSSI=1 adds a third SEQUENTIAL ssh read per
#      reading (RF level + hardware gain, device located by capability at runtime).
set -u
D=$(cd "$(dirname "$0")" && pwd)          # two_jup/rxfix
TJ=$(cd "$D/.." && pwd)                   # two_jup
# SSH override exists so a DRY=0 test can point every board read at a shim; a real
# run leaves it unset and gets anyssh.sh. Without this, brd() would reach the board
# even from a test that thought it had shimmed everything.
W=${SSH:-$TJ/anyssh.sh}
COMB=$TJ/comb
DRY=${DRY:-1}
MODE=${MODE:?usage: MODE=ctrl|air w1leg_go.sh}
DUR=${DUR:-600}
PERIOD=${PERIOD:-10}
FIXCTL_BASE=${FIXCTL_BASE:-0x0}
EXP_SET=${EXP:+1}
EXP=${EXP:-2728dab3979a}
# R4B=1 tells w1_read.sh to sweep the NINTH word 0x234 as well (W1+R4B images only;
# it reads const_0 on a W1-only image).  Default 0 = Task 10 behaviour unchanged.
R4B=${R4B:-0}
case "$R4B" in 0|1) ;; *) echo "R4B must be 0 or 1" >&2; exit 2 ;; esac
# FAIL-CLOSED PAIRING OF R4B WITH THE IMAGE GATE.  EXP defaults to the W1 image
# 2728dab3979a.  A leg run with R4B=1 against that default would PASS the image gate
# while the W1-only image is on the board, read const_0 at 0x234, and score the Task 13
# pre-registration against W1 silicon -- T13-P1 would "fail" and F-B would "fire" on a
# leg that never had R4B in it at all.  So R4B=1 must name its own image explicitly.
if [ "$R4B" = 1 ] && { [ -z "${EXP_SET:-}" ] || [ "$EXP" = 2728dab3979a ]; }; then
  echo "W1LEG_REFUSED R4B=1 requires an explicit EXP=<the W1+R4B image md5-12>; EXP is '$EXP'" >&2
  exit 2
fi
RATE_GATE=${RATE_GATE:-900}

# --- LEG / BOARD / RSSI (Task 17) -------------------------------------------
# LEG   = which air leg legrun_go.sh runs (A: 146 TX -> 148 RX; B: 148 TX -> 146 RX)
# BOARD = the board this script READS (the RX board of that leg)
# RSSI  = add a THIRD sequential ssh read per reading: RF level + gain on BOARD
# Defaults LEG=A BOARD=148 reproduce Task 10/13 behaviour exactly.
LEG=${LEG:-A}
BOARD=${BOARD:-148}
RSSI=${RSSI:-0}
case "$LEG"   in A|B) ;;     *) echo "LEG must be A or B" >&2; exit 2 ;; esac
case "$BOARD" in 148|146) ;; *) echo "BOARD must be 148 or 146" >&2; exit 2 ;; esac
case "$RSSI"  in 0|1) ;;     *) echo "RSSI must be 0 or 1" >&2; exit 2 ;; esac
# The reader must read the RECEIVER. Mixing these up would sweep the ring witness on
# the TRANSMITTING board and silently score the wrong side of the link, so it is a
# refusal, not a warning.
case "$LEG:$BOARD" in
  A:148|B:146) ;;
  *) echo "W1LEG_REFUSED LEG=$LEG requires BOARD=$( [ "$LEG" = A ] && echo 148 || echo 146 ) (the RX board); got BOARD=$BOARD" >&2; exit 2 ;;
esac
case "$BOARD" in 148) BOARD_IP=10.0.0.148 ;; 146) BOARD_IP=10.0.0.146 ;; esac
A_IP=$BOARD_IP
# AUX addresses swept in the SAME ssh round trip as the W1 sweep (never a extra trip).
# 0x104 packets_out, 0x124 cnt_frame_start. On an AIR leg 0x150 (rstcs, the carrier-reset
# counter) is added so the leg carries a per-reading carrier-reset timeline -- the
# standing measurement the controller added on 2026-09-05 (PREREG sec 5.2). MODE=ctrl
# keeps the original two addresses so its control table stays byte-comparable with
# Task 13's.
AUXA="0x104 0x124"
AUXAIR="0x104 0x124 0x150"
DM='DM=$(command -v devmem || echo "busybox devmem")'

case "$MODE" in ctrl|air) ;; *) echo "MODE must be ctrl or air" >&2; exit 2 ;; esac

TS=$(date +%Y%m%d_%H%M%S)
TAG=${TAG:-$MODE}
OUT=${OUT:-$COMB/runs/${TS}_w1_${TAG}}
mkdir -p "$OUT"
log(){ echo "$(date -Is) $*" | tee -a "$OUT/run.log"; }
log "=== w1leg_go.sh MODE=$MODE dur=$DUR period=$PERIOD fixctl_base=$FIXCTL_BASE dry=$DRY -> $OUT ==="
log "FIXCTL_BASE=$FIXCTL_BASE stated explicitly (enSlack=0, DBGCAP mux bits 12/13=0)"
log "R4B=$R4B (1 = also sweep the ninth word 0x234, {locked, skips[15:0], opens[14:0]})"

brd(){ if [ "$DRY" = 1 ]; then echo "[dry] $*"; else timeout 60 $W $A_IP "$@" 2>/dev/null | tr -d '\r'; fi; }

# --- preflight: which image is actually on the board -----------------------
IMG=$(brd 'md5sum /boot/BOOT.BIN | cut -c1-12')
log "board image readback: $IMG (expect $EXP)"
if [ "$DRY" != 1 ] && [ "$IMG" != "$EXP" ]; then
  log "W1LEG_REFUSED: board image $IMG != expected $EXP"
  echo "W1LEG_REFUSED image=$IMG"; exit 4
fi

# --- one w1 read into its own dir ------------------------------------------
w1read(){ # $1 subdir  $2 N  $3 HOLD  [$4 AUX override]
  DRY=$DRY BOARD=$BOARD N=$2 PERIOD=$PERIOD FREEZE=1 FIXCTL_BASE=$FIXCTL_BASE R4B=$R4B \
    AUX="${4:-$AUXA}" HOLD=$3 OUT="$OUT/$1" SSH=${SSH:-$W} bash "$D/w1_read.sh" >>"$OUT/w1_read.log" 2>&1
}

# --- RSSI / gain reader (Task 17) -------------------------------------------
# A THIRD ssh round trip, run strictly AFTER the W1 sweep and the checker read -- never
# concurrent with them. The W1/checker reads go through the single shared
# direct_reg_access address-select register; this one reads sysfs only, but it still
# runs sequentially so the reading period stays a clean serial sum and no ssh session
# can interleave.
# THE DEVICE IS FOUND BY CAPABILITY AT RUNTIME, NEVER BY INDEX: iio:deviceN numbering
# is not stable across kernels/boots. We pick the first iio device that actually exposes
# in_voltage0_rssi and FAIL LOUDLY if none does.
RSSI_REMOTE='D=""; for d in /sys/bus/iio/devices/iio:device*; do [ -e "$d/in_voltage0_rssi" ] && { D=$d; break; }; done; \
if [ -z "$D" ]; then echo "RSSI_DEV_NOT_FOUND"; exit 9; fi; \
printf "dev=%s name=%s rssi=%s gain=%s decpwr=%s\n" "$(basename $D)" "$(cat $D/name 2>/dev/null)" \
  "$(cat $D/in_voltage0_rssi 2>/dev/null || echo NA)" \
  "$(cat $D/in_voltage0_hardwaregain 2>/dev/null || echo NA)" \
  "$(cat $D/in_voltage0_decimated_power 2>/dev/null || echo NA)"'
rssi_read(){ # $1 iteration index -> one line appended to $OUT/rssi.jsonl
  [ "$RSSI" = 1 ] || return 0
  local raw ts
  ts=$(date -Is)
  if [ "$DRY" = 1 ]; then raw="dev=iio:device2 name=adrv9002-phy rssi=[dry] gain=[dry] decpwr=[dry]"
  else raw=$(timeout 30 $W "$BOARD_IP" "$RSSI_REMOTE" 2>/dev/null | tr -d "\r" | tail -1); fi
  [ -n "$raw" ] || raw="RSSI_READ_FAILED"
  printf '{"i":%s,"t":"%s","board":"%s","raw":"%s"}\n' "$1" "$ts" "$BOARD" "$raw" >> "$OUT/rssi.jsonl"
  case "$raw" in RSSI_DEV_NOT_FOUND*|RSSI_READ_FAILED*) log "RSSI WARN reading $1: $raw" ;; esac
}

# ===========================================================================
# MODE=ctrl -- Step 2
# ===========================================================================
if [ "$MODE" = ctrl ]; then
  SINK_ARMED=0
  sink_off(){ [ "$SINK_ARMED" = 1 ] || return 0; SINK_ARMED=0
    if [ "$DRY" = 1 ]; then log "[dry] SINK=tgenrx disarm: RMW clear 0x9D410000 bit0"
    else log "SINK=tgenrx disarm: $(brd "$DM; C=\$(\$DM 0x9D410000); \$DM 0x9D410000 32 \$(( C & ~1 )); \$DM 0x9D410000")"; fi; }
  trap sink_off EXIT INT TERM

  log "--- arm #1: arm148_mode1.sh (148-only mode-1 internal loopback) ---"
  if [ "$DRY" = 1 ]; then log "[dry] bash $TJ/arm148_mode1.sh"; ARM1="[dry] ARM_OK fps=1246"
  else ARM1=$(bash "$TJ/arm148_mode1.sh" 2>&1 | tail -3); fi
  log "arm #1: $ARM1"
  echo "$ARM1" | grep -q ARM_OK || [ "$DRY" = 1 ] || { log "W1LEG_ABORT: arm #1 not ARM_OK"; echo "W1LEG_ABORT arm1"; exit 5; }

  # SINK=tgenrx, exactly seqbist_run.sh's RMW contract (bit0 set; 3/4/5 preserved)
  if [ "$DRY" = 1 ]; then log "[dry] SINK=tgenrx arm: RMW set 0x9D410000 bit0"
  else log "SINK=tgenrx arm: $(brd "$DM; C=\$(\$DM 0x9D410000); \$DM 0x9D410000 32 \$(( C | 1 )); echo pre=\$C post=\$(\$DM 0x9D410000)")"; fi
  SINK_ARMED=1

  log "--- reads 1-3 (10 s apart), pre-re-arm ---"
  w1read reads_pre 3 0
  log "--- freeze-path control: ONE read with the freeze HELD for 10 s ---"
  log "    (both frozen sweeps inside one 10 s freeze window; every delta must be 0)"
  w1read reads_freeze 1 10
  log "--- arm #2: ONE re-arm (the edge-counter liveness positive control) ---"
  if [ "$DRY" = 1 ]; then log "[dry] bash $TJ/arm148_mode1.sh (re-arm)"; ARM2="[dry] ARM_OK fps=1246"
  else ARM2=$(bash "$TJ/arm148_mode1.sh" 2>&1 | tail -3); fi
  log "arm #2: $ARM2"
  log "--- reads 4-6 (10 s apart), post-re-arm ---"
  w1read reads_post 3 0
  sink_off

  if [ "$DRY" != 1 ]; then
    python3 "$D/w1_score.py" "$OUT/reads_pre"  --mode ctrl --label "pre-re-arm"  > "$OUT/verdict_pre.txt"  2>&1 || true
    python3 "$D/w1_score.py" "$OUT/reads_post" --mode ctrl --label "post-re-arm" > "$OUT/verdict_post.txt" 2>&1 || true
    python3 "$D/w1_ctl.py" "$OUT" > "$OUT/verdict.txt" 2>&1 || true
    cat "$OUT/verdict.txt"
  else
    echo "[dry] would score reads_pre / reads_freeze / reads_post" > "$OUT/verdict.txt"
  fi
  { echo "mode=ctrl board=148 image=$IMG fixctl_base=$FIXCTL_BASE r4b=$R4B dry=$DRY"
    echo "arm1=$(echo "$ARM1" | tr '\n' ' ')"
    echo "arm2=$(echo "$ARM2" | tr '\n' ' ')"
    echo "sink=tgenrx (armed for the run, disarmed on exit)"
    echo "aux=$AUXA (0x104 packets_out, 0x124 cnt_frame_start; NOT frozen)"
    echo "ts=$(date -Is)"; } > "$OUT/meta.txt"
  cat "$OUT/meta.txt"
  echo "W1LEG_CTRL_DONE $OUT"
  exit 0
fi

# ===========================================================================
# MODE=air -- Step 3
# ===========================================================================
LEGLOG="$OUT/capture_r3.log"
READ_WIN=$(( DUR - 120 )); [ "$READ_WIN" -lt 150 ] && READ_WIN=150
log "air leg: LEG=$LEG BOARD=$BOARD ($BOARD_IP) DUR=$DUR RATE_GATE=$RATE_GATE RSSI=$RSSI, reader window ${READ_WIN}s at ${PERIOD}s cadence"
log "air AUX=$AUXAIR (0x150 = rstcs, the per-reading carrier-reset timeline; PREREG sec 5.2)"

TGEN_TOUCHED=0
tgen_restore(){ [ "$TGEN_TOUCHED" = 1 ] || return 0; TGEN_TOUCHED=0
  if [ "$DRY" = 1 ]; then log "[dry] restore tgen_mode (RMW set 0x9D410000 bit5)"
  else log "tgen_mode restored: $(brd "$DM; C=\$(\$DM 0x9D410000); \$DM 0x9D410000 32 \$(( C | 32 )); \$DM 0x9D410000")"; fi; }
trap tgen_restore EXIT INT TERM

# ---- the reader loop, started in the background but doing ONE thing at a time
reader_bg(){
  local waited=0 max=480
  # Wait for capture_r3.sh's own health gate to resolve.  "wedge verdict:" is printed
  # (capture_r3.sh:198) AFTER any wedge re-arm and BEFORE the framelog rotate that
  # opens the scored window -- the same marker slackleg_go.sh keys its peer write on.
  # Also refuse while a bring-up/restore script is in flight: a direct_reg_access read
  # during an ADRV9002 profile reload is the documented board hang.
  while :; do
    if grep -q "wedge verdict:" "$LEGLOG" 2>/dev/null \
       && ! ps -eo args | grep -qE "^(/bin/bash|bash|/bin/sh) (/mnt/onetb/scratch/qpsk-jupiter-modem/two_jup/)?(bringup_r2r3|restore_known_good|soak_bidir)\.sh"; then
      echo "$(date -Is) health gate resolved after ${waited}s; opening the reader window" >> "$OUT/reader.log"
      break
    fi
    [ "$waited" -ge "$max" ] && { echo "$(date -Is) READER_ABORT: no health gate within ${max}s" >> "$OUT/reader.log"; return 7; }
    sleep 5; waited=$((waited+5))
  done
  sleep 5

  # HOST-FRAME mode for the checker, exactly stage3h_reader.sh's RMWs (bit0 untouched)
  local C0 C1 C2
  C0=$(brd "$DM; \$DM 0x9D410000")
  C1=$(brd "$DM; C=\$(\$DM 0x9D410000); \$DM 0x9D410000 32 \$(( C & ~32 )); \$DM 0x9D410000")
  C2=$(brd "$DM; C=\$(\$DM 0x9D410000); \$DM 0x9D410000 32 \$(( C & ~16 )); sleep 0.05; \$DM 0x9D410000 32 \$(( C | 16 )); \$DM 0x9D410000")
  TGEN_TOUCHED=1
  echo "$(date -Is) checker ctrl pre=$C0 hostframe=$C1 cleared=$C2" >> "$OUT/reader.log"

  mkdir -p "$OUT/reads"
  : > "$OUT/reads/readings.jsonl"
  : > "$OUT/chk.jsonl"
  local i=1 t0 tend now
  t0=$(date +%s); tend=$(( t0 + READ_WIN ))
  while :; do
    now=$(date +%s); [ "$now" -ge "$tend" ] && break
    # --- ssh #1: the W1 sweep (freeze -> two sweeps -> aux -> unfreeze) -----
    w1read "reads/i$i" 1 0 "$AUXAIR"
    cat "$OUT/reads/i$i/readings.jsonl" >> "$OUT/reads/readings.jsonl" 2>/dev/null
    # --- ssh #2: the SEQ-BIST checker, strictly AFTER #1 has returned -------
    python3 "$TJ/seqbist/seqbist_read.py" "$BOARD" >> "$OUT/chk.jsonl" 2>>"$OUT/reader.log"
    # --- ssh #3: RSSI/gain, strictly AFTER #2 (RSSI=1 only) ----------------
    # PERIOD DISCIPLINE: the reading period must stay 10.0 s. If the three serial
    # round trips overrun 12 s, the RSSI read drops to EVERY SECOND reading rather
    # than stretching the cadence -- the W1 deltas are what the period must protect.
    if [ "$RSSI" = 1 ]; then
      if [ "${RSSI_EVERY2:-0}" = 1 ] && [ $(( i % 2 )) -ne 1 ]; then :; else rssi_read "$i"; fi
    fi
    now=$(date +%s)
    if [ "$RSSI" = 1 ] && [ "${RSSI_EVERY2:-0}" = 0 ] && [ $(( now - (t0 + (i-1)*PERIOD) )) -gt 12 ]; then
      RSSI_EVERY2=1
      echo "$(date -Is) reading $i took >12s; RSSI drops to every second reading to hold the ${PERIOD}.0s cadence" >> "$OUT/reader.log"
      log "RSSI cadence guard fired at reading $i: RSSI now every second reading"
    fi
    local slp=$(( t0 + i*PERIOD - now ))
    [ "$slp" -gt 0 ] && sleep "$slp"
    i=$((i+1))
  done
  echo "$(date -Is) reader window closed after $((i-1)) iterations" >> "$OUT/reader.log"
  tgen_restore
}

if [ "$DRY" = 1 ]; then
  log "[dry] reader plan: wait for 'wedge verdict:' in $LEGLOG and no bring-up in flight"
  log "[dry] reader plan: RMW 0x9D410000 clear bit5 (host-frame), pulse bit4 (checker clear)"
  log "[dry] reader plan: ${READ_WIN}s window, every ${PERIOD}s SEQUENTIALLY: w1_read.sh (ssh #1) then seqbist_read.py (ssh #2)$( [ "$RSSI" = 1 ] && echo " then rssi_read (ssh #3)" )"
  log "[dry] reader plan: restore tgen_mode (RMW set bit5) at window close"
  READER_PID=""
else
  reader_bg & READER_PID=$!
  log "reader started (pid $READER_PID), waiting on $LEGLOG"
fi

log "leg: legrun_go.sh LEG=$LEG DUR=$DUR RATE_GATE=$RATE_GATE OUT=$OUT"
LEG_RC=0
DRY=$DRY LEG=$LEG DUR=$DUR TAG="$TAG" OUT="$OUT" RATE_GATE=$RATE_GATE "$COMB/legrun_go.sh" || LEG_RC=$?
log "legrun_go.sh exit=$LEG_RC"
if [ -n "$READER_PID" ]; then wait "$READER_PID" 2>/dev/null; log "reader joined"; fi
tgen_restore

if [ "$DRY" != 1 ] && [ -s "$OUT/reads/readings.jsonl" ]; then
  python3 "$D/w1_score.py" "$OUT/reads" --mode air --label "fwd air leg" > "$OUT/verdict.txt" 2>&1 || true
  cp -f "$OUT/reads/w1_reads.csv" "$OUT/w1_reads.csv" 2>/dev/null
  cat "$OUT/verdict.txt"
else
  echo "[dry] would score $OUT/reads" > "$OUT/verdict.txt"
fi

LEG_META=""; [ -f "$OUT/meta.txt" ] && LEG_META=$(cat "$OUT/meta.txt")
{ echo "$LEG_META"
  echo "mode=air board=148 image=$IMG fixctl_base=$FIXCTL_BASE r4b=$R4B"
  echo "read_window_s=$READ_WIN period=$PERIOD aux=$AUXA"
  echo "reader=sequential (w1_read.sh then seqbist_read.py, never concurrent -- shared DRA address-select)"
  echo "leg_exit=$LEG_RC"
  echo "ts=$(date -Is)"; } > "$OUT/meta.txt"
cat "$OUT/meta.txt"

if [ "$LEG_RC" = 0 ]; then echo "W1LEG_AIR_DONE $OUT"
else echo "W1LEG_AIR_GATE_FAIL $OUT (legrun_go.sh exit=$LEG_RC -- treat as UNINFORMATIVE)"; exit 3; fi
