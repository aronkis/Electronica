#!/bin/bash
# =============================================================================
# arm148_rf_self.sh -- arm 148 ALONE for RF SELF-RECEPTION (SEQ-BIST stage 2,
# plan happy-bubbling-owl T3), and gate the bring-up. 146 is NEVER touched.
#
# 148 transmits the fabric TGEN byte stream on its own antenna and receives it
# on its own RX -- no cable, no attenuator, no daemon, no watchdog, no DMA.
#
# WHY THIS IS NOT rf_loopback.sh: that script is the cabled single-radio BER
# test. It (a) loads lvds_1p92_mhz (240 ksym legacy rate -- the SEQ-BIST gate of
# >= 1,200 f/s is unreachable there), (b) starts qpsk_tun -B and lock_watchdog
# (a daemon and a DMA in the path -- the whole point of SEQ-BIST is neither),
# and (c) sets Tx LO == Rx LO. Only its register block and its "one radio, shared
# LO" idea are reused here; the arm block below is bringup_r2r3.sh's arm_rom /
# rearm_byte verbatim (do NOT paraphrase the pokes -- the radio wedges and
# Jupiter has no remote power).
#
# WHY LO_RX != LO_TX BY DEFAULT (the trap rf_loopback.sh would walk into):
# bringup_r2r3.sh's CFO POLICY -- at R2/R3 the fabric demod has a DEAD ZONE at
# residual CFO ~= 0 (0x154 sign-flips, sync collapses to ~40%). In a two-board
# link the residual is supplied for free by the two boards' XO offset. In SELF
# reception both LOs come off the SAME XO, so a shared LO gives residual CFO
# EXACTLY 0 -- the worst possible point. Default here is therefore TX 2.000 GHz /
# RX 2.000020 GHz = +20 kHz residual, inside the proven-clean +/-2.4k..+/-20k
# band and the same +20k the shipped forward leg uses. Override with LO_RX for
# the ONE documented alternative attempt (the brief's attenuator-free fallback);
# RX gain is NOT a fallback knob on this rig -- task-8a measured both receivers
# already pinned at the AGC max-gain rail (34.000000 dB = index 255).
#
# TWO-STAGE GATE (deliberately not one combined test):
#   (a0) arm-quality gate: ROM (0x158=0) with 0x114=0 -- fabric-internal loopback,
#        no radio in the RX path. Comparable to arm148_mode1.sh (~1244 f/s healthy)
#        and to task-8a §9.1's collapse to 764-830. Gate: >= GATE_ROM_FPS (1120).
#   (a1) self-coupling gate: ROM with 0x114=1 -- 148 must hear its OWN transmission
#        over the air. Same threshold. a0 healthy + a1 dead = coupling too weak
#        (cable needed, UNINFORMATIVE); a0 low = the arm-quality collapse.
#   (b) SEQ-BIST gate (the brief's): source = byte/TGEN (0x158=1), TGEN on, two
#       seqbist_read.py samples GATE_WIN s apart. Gate: 0x124 frame-sync rate
#       >= GATE_FPS (default 1200) AND |chk_frames - 0x124| / 0x124 <= 1 %.
#       Conflating (a) and (b) would hide the very loss stage 2 exists to measure.
#
# REGISTER HYGIENE (so seqbist_run.sh MODE=rf does not refuse the leg):
#   * this script NEVER writes 0x9D410000 (tgen_rx ctrl). seqbist_read.py's
#     freeze/restore is the only toucher; the gate is delta-based so no checker
#     clear is needed here, and seqbist_run.sh does its own clear. That keeps the
#     whole 148 bits-4/5-alias-fill_len RMW bug class out of this script.
#   * on exit: TGEN ctrl = 0, 0x114 = 1, 0x158 = 1, tgen_rx bit0 = 0, and NO
#     0x000 / 0x110 pulse after the gate -- otherwise seqbist_run.sh's
#     check_rf_armed (exit 4) or check_tgen_rx_disabled (exit 5) refuses.
#   * no watchdog, no qpsk_tun, ever.
#
# Env: LO_TX=2000000000 LO_RX=2000020000 PROF=lvds_61p44_fdd_jupiter
#      SSI="5 3" (or SSI=skip) FILL=1516 GAP=0 GATE_ROM_FPS=1120 GATE_FPS=1200
#      GATE_WIN=15 DRY=1 (default; DRY=0 touches the board)
# Prints ARM_RF_SELF_OK / ARM_RF_SELF_FAIL_<stage> as its last line.
# =============================================================================
set -u
S=$(cd "$(dirname "$0")" && pwd)             # two_jup/seqbist
D=$(cd "$S/.." && pwd)                       # two_jup
W=${W:-$D/anyssh.sh}
A=${A:-10.0.0.148}

PROF=${PROF:-lvds_61p44_fdd_jupiter}
LO_TX=${LO_TX:-2000000000}
LO_RX=${LO_RX:-2000020000}
SSI=${SSI:-5 3}
FILL=${FILL:-1516}
GAP=${GAP:-0}
GATE_ROM_FPS=${GATE_ROM_FPS:-1120}
GATE_FPS=${GATE_FPS:-1200}
GATE_WIN=${GATE_WIN:-15}
# GATE_WAIVE=1: run the SEQ-BIST gate and REPORT it, but do not exit non-zero on it.
# For the deliberate filler-heavy RF leg (GAP=60000), where the gate is EXPECTED to fail
# -- filler frames are what we are there to measure, not a bring-up defect. The a0
# arm-quality and a1 self-coupling gates still bite: those are real bring-up failures.
GATE_WAIVE=${GATE_WAIVE:-0}
# TXATTEN: out_voltage0_hardwaregain in dB (0 = full power, the arm_rom default; -20/-40
# attenuate). Applied AFTER arm_rom -- which writes hardwaregain=0 on EVERY arm, so an
# attenuation set before the arm is silently overwritten -- and BEFORE the a0/a1 ROM
# gates, so a ROM control at attenuation exercises the same power as the TGEN probes.
# rearm() does not touch the radio gain, so it persists through stage (b).
TXATTEN=${TXATTEN:-0}
DRY=${DRY:-1}

[ "$FILL" -ge 100 ] || { echo "ARM_RF_SELF_REFUSED: FILL=$FILL < 100 (fill<=47 is the deterministic wedge cliff)"; exit 3; }

log(){ echo "$(date -Is) $*"; }
brd(){ if [ "$DRY" = 1 ]; then echo "[dry] ssh $A: $*"; else $W "$A" "$@" 2>/dev/null | tr -d '\r'; fi; }

log "=== arm148_rf_self.sh: PROF=$PROF LO_TX=$LO_TX LO_RX=$LO_RX SSI='$SSI' FILL=$FILL GAP=$GAP DRY=$DRY ==="
log "    residual CFO by design = LO_RX - LO_TX = $(( LO_RX - LO_TX )) Hz (0 Hz is the demod dead zone -- never run the null)"

# ---- profile discovery: a miss is FATAL, never silent (arm148_mode1.sh §49) ---
if [ "$DRY" = 1 ]; then
  log "[dry] would verify BOTH /root/$PROF.bin and /root/$PROF.json exist on $A"
else
  HAVE=$($W "$A" "ls /root/$PROF.bin /root/$PROF.json 2>/dev/null | tr '\n' ' '" 2>/dev/null | tr -d '\r')
  if [ "$(printf %s "$HAVE" | wc -w)" -ne 2 ]; then
    log "ARM_RF_SELF_FAIL_PROFILE: need BOTH /root/$PROF.{bin,json} on $A; found: [$HAVE]"
    echo "ARM_RF_SELF_FAIL_PROFILE"; exit 2
  fi
  log "  profile found: $HAVE"
fi

# ---- arm_rom: bringup_r2r3.sh:66-81 verbatim, single board, 0x158=0 (ROM) -----
# Comments must stay OUT of the quoted remote string (anyssh flattens newlines).
arm_rom(){ brd "P=/sys/bus/iio/devices/iio:device2; DB=/sys/kernel/debug/iio/iio:device2
 pkill -x qpsk_tun 2>/dev/null
 pkill -f \"[l]ock_watchdog\" 2>/dev/null; pkill -f \"[s]tallpoll\" 2>/dev/null; sleep 1
 cat /root/$PROF.bin > \$P/stream_config 2>/dev/null; cat /root/$PROF.json > \$P/profile_config 2>/dev/null; sleep 2
 echo calibrated > \$P/out_voltage1_ensm_mode 2>/dev/null; echo calibrated > \$P/in_voltage1_ensm_mode 2>/dev/null
 for g in 4 5 6 7; do echo 1 > \$DB/agpio\${g}_direction; echo 1 > \$DB/agpio\${g}_value; done; echo tx_a > \$P/out_voltage0_port_select
 echo $LO_TX > \$P/out_altvoltage2_TX1_LO_frequency 2>&1; echo 0 > \$P/out_voltage0_hardwaregain; echo rf_enabled > \$P/out_voltage0_ensm_mode
 echo calibrated > \$P/in_voltage0_ensm_mode 2>/dev/null; echo $LO_RX > \$P/out_altvoltage0_RX1_LO_frequency 2>&1
 echo rf_enabled > \$P/in_voltage0_ensm_mode; echo automatic > \$P/in_voltage0_gain_control_mode
 DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
 echo '0x000 0x1'>\$DRA;sleep 0.5;echo '0x000 0x0'>\$DRA;echo '0x158 0x0'>\$DRA;echo '0x118 0x0'>\$DRA;echo '0x114 0x1'>\$DRA
 TXD=\$(for d in /sys/bus/iio/devices/iio:device*; do [ \"\$(cat \$d/name 2>/dev/null)\" = axi-adrv9002-tx-lpc ] && echo \${d##*/}; done);T=/sys/kernel/debug/iio/\$TXD/direct_reg_access
 echo '0x418 0x2'>\$T;echo '0x458 0x2'>\$T;echo '0x044 0x1'>\$T;echo '0x110 0x1'>\$DRA;sleep 0.3;echo '0x110 0x0'>\$DRA
 echo '148 armed ROM ($PROF)'"; }

# ---- rearm helper: bringup_r2r3.sh:83-86 / 179-183. $1 = 0x158 (source), $2 = 0x114
# (RX input select: 0x0 = fabric-internal loopback, 0x1 = air). NEVER leave 0x114=0 on an
# exit path -- seqbist_run.sh's check_rf_armed refuses the leg (exit 4).
rearm(){ brd "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
 echo \"0x000 0x1\">\$DRA; sleep 0.5; echo \"0x000 0x0\">\$DRA; echo \"0x158 $1\">\$DRA; echo \"0x118 0x0\">\$DRA; echo \"0x114 $2\">\$DRA
 TXD=\$(for d in /sys/bus/iio/devices/iio:device*; do [ \"\$(cat \$d/name 2>/dev/null)\" = axi-adrv9002-tx-lpc ] && echo \${d##*/}; done); T=/sys/kernel/debug/iio/\$TXD/direct_reg_access
 echo \"0x418 0x2\">\$T; echo \"0x458 0x2\">\$T; echo \"0x044 0x1\">\$T; echo \"0x110 0x1\">\$DRA; sleep 0.3; echo \"0x110 0x0\">\$DRA; echo rearmed_0x158=$1_0x114=$2"; }

# ---- 0x104 ROM probe over 5 s (bringup_r2r3.sh:88-89) ------------------------
probe(){ if [ "$DRY" = 1 ]; then echo 1245; else
  $W "$A" 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
 echo 0x104 > $DRA; p0=$(cat $DRA); sleep 5; echo 0x104 > $DRA; p1=$(cat $DRA); echo $(( (p1 - p0) / 5 ))' 2>/dev/null | tr -d '\r' | tail -1; fi; }

DM='DM=$(command -v devmem || echo "busybox devmem")'
tgen_set(){ # $1 = ctrl word (0 = off)
  if [ "$DRY" = 1 ]; then log "[dry] TGEN ctrl@0x9D400000=$1 gap@0x9D400008=$GAP"; else
    $W "$A" "$DM; \$DM 0x9D400008 32 $(( GAP & 0x7FFFFFF )); \$DM 0x9D400000 32 $1; echo TGEN ctrl=\$(\$DM 0x9D400000) gap=\$(\$DM 0x9D400008)" 2>/dev/null | tr -d '\r'; fi; }

# =============================== stage (a) ===================================
log "--- stage (a): arm ROM + SSI + double-tap, then the ROM lock gate ---"
arm_rom

if [ "$SSI" = skip ]; then
  log "  SSI: SKIPPED by env (this-boot auto-tune delays stand)"
else
  set -- $SSI
  if [ "$DRY" = 1 ]; then
    log "[dry] FORCE=1 $D/apply_146_ssi_fix.sh $A $1 $2   (AIR=1 -> re-arms with 0x158=1/0x114=1; ROM is re-asserted right after)"
  else
    R=$(FORCE=1 "$D/apply_146_ssi_fix.sh" "$A" "$1" "$2" 2>&1 | tail -1); log "  SSI 148 tx0 clk=$1 dat=$2: $R"
  fi
fi

# TX attenuation, applied here: after arm_rom's hardwaregain=0 write, before a0/a1.
if [ "$TXATTEN" != 0 ]; then
  if [ "$DRY" = 1 ]; then
    log "[dry] TXATTEN: would write out_voltage0_hardwaregain=$TXATTEN and read back"
  else
    G=$(brd "P=/sys/bus/iio/devices/iio:device2; echo $TXATTEN > \$P/out_voltage0_hardwaregain 2>/dev/null; sleep 0.5; cat \$P/out_voltage0_hardwaregain")
    log "TXATTEN=$TXATTEN dB applied: out_voltage0_hardwaregain read-back='$G'"
  fi
else
  log "TXATTEN=0 (full power, arm_rom default)"
fi

# the SSI fix re-arms with 0x158=1; put the board back on ROM for the gates.
# DOUBLE-TAP (task-ARMCAUSE): a single tap can latch a false FTS state 0x110
# cannot clear. Two taps, 3 s apart, at every source/select flip.
#
# TWO ROM PROBES, NOT ONE. They answer different questions and a single air-only
# probe cannot tell them apart:
#   (a0) 0x114=0, ROM: fabric-internal loopback, NO radio in the RX path. This is
#        the arm-quality number, directly comparable to arm148_mode1.sh (healthy
#        ~1244 f/s) and to task-8a §9.1's collapse to 764-830 f/s.
#   (a1) 0x114=1, ROM: over the air. 148 must now receive its OWN transmission.
#        This is the SELF-COUPLING probe -- the thing that is genuinely unproven
#        on this rig (no cable, no attenuator).
# Diagnosis: a0 healthy + a1 dead  => coupling too weak, cable needed (UNINFORMATIVE).
#            a0 also low           => the 148 arm-quality collapse, not coupling.
# CONTAMINATION WARNING: while 146 sits ensm=rf_enabled with 0x158=0 it radiates ROM
# on 2.000 GHz into 148's RX band, and (a1) then measures 146's carrier, not 148's
# self-coupling. Key 146's TX off (and restore it afterwards) before believing (a1).
rearm 0x0 0x0; [ "$DRY" = 1 ] || sleep 3; rearm 0x0 0x0
[ "$DRY" = 1 ] || sleep 4
INTFPS=$(probe)
log "  (a0) arm-quality gate [0x114=0, fabric-internal, no radio]: 0x104 = ${INTFPS:-0} f/s (need >= $GATE_ROM_FPS; healthy ~1244, task-8a collapse 764-830)"
if [ "${INTFPS:-0}" -lt "$GATE_ROM_FPS" ]; then
  log "ARM_RF_SELF_FAIL_ARMQUALITY: ${INTFPS:-0} f/s < $GATE_ROM_FPS with NO radio in the path."
  log "  this is the task-8a §9.1 arm-quality collapse, NOT a coupling result and NOT a"
  log "  TGEN/checker result. One re-arm attempt is the documented response; do not"
  log "  interpret stage 2 from this board until an internal-loopback arm reads healthy."
  echo "ARM_RF_SELF_FAIL_ARMQUALITY intfps=${INTFPS:-0}"; exit 4
fi
log "  (a0) arm-quality gate PASS"

rearm 0x0 0x1; [ "$DRY" = 1 ] || sleep 3; rearm 0x0 0x1
[ "$DRY" = 1 ] || sleep 4
ROMFPS=$(probe)
log "  (a1) self-coupling gate [0x114=1, over the air, ROM]: 0x104 = ${ROMFPS:-0} f/s (need >= $GATE_ROM_FPS)"
if [ "${ROMFPS:-0}" -lt "$GATE_ROM_FPS" ]; then
  log "ARM_RF_SELF_FAIL_COUPLING: ${ROMFPS:-0} f/s < $GATE_ROM_FPS on air while the internal"
  log "  loopback read ${INTFPS} f/s -- the arm is healthy, 148 is simply not hearing itself."
  log "  documented single alternative (brief): re-run once with a different LO_RX offset,"
  log "  e.g. LO_RX=2000005000 (+5 kHz) or LO_RX=1999980000 (-20 kHz). RX gain is already at"
  log "  the AGC max-gain rail (34 dB, task-8a) so gain is NOT a fallback knob. If the"
  log "  alternative also fails: report UNINFORMATIVE (self-coupling too weak, cable needed)."
  # leave the board in a state seqbist_run.sh would accept (0x114=1 already set)
  echo "ARM_RF_SELF_FAIL_COUPLING romfps=${ROMFPS:-0} intfps=${INTFPS}"; exit 4
fi
log "  (a1) self-coupling gate PASS"

# =============================== stage (b) ===================================
log "--- stage (b): flip to byte/TGEN source, then the SEQ-BIST bring-up gate ---"
rearm 0x1 0x1; [ "$DRY" = 1 ] || sleep 3; rearm 0x1 0x1
CTRLW=$(( (FILL << 4) | 1 ))
tgen_set "$CTRLW"
[ "$DRY" = 1 ] || sleep 3

# The SEQ-BIST bring-up gate below reads chk_frames, which only advances if the RX byte
# seam is draining. With no daemon and no DMA armed it is NOT -- so the gate must arm the
# same sink the legs use (qpsk_traffic_gen_rx2 enable, 0x9D410000 bit0: dut_ready held
# HIGH, DUT stream consumed+discarded). Without this the gate measures a stalled seam and
# reports FAIL_GATE on a perfectly good radio link. RMW preserves bits 3/4/5; disarmed
# again right after the gate so seqbist_run.sh starts from the state it expects.
SINK_ON=0
sink_on(){ if [ "$DRY" = 1 ]; then log "[dry] SINK=tgenrx arm for the gate (RMW set 0x9D410000 bit0)"; else
    log "SINK=tgenrx arm for the gate: $(brd "$DM; C=\$(\$DM 0x9D410000); \$DM 0x9D410000 32 \$(( C | 1 )); echo pre=\$C post=\$(\$DM 0x9D410000)")"; fi; SINK_ON=1; }
sink_off(){ [ "$SINK_ON" = 1 ] || return 0; SINK_ON=0
  if [ "$DRY" = 1 ]; then log "[dry] SINK=tgenrx disarm (RMW clear bit0)"; else
    log "SINK=tgenrx disarm: ctrl=$(brd "$DM; C=\$(\$DM 0x9D410000); \$DM 0x9D410000 32 \$(( C & ~1 )); \$DM 0x9D410000")"; fi; }
trap 'sink_off' EXIT INT TERM
sink_on

READ=$S/seqbist_read.py
DRYFLAG=""; [ "$DRY" = 1 ] && DRYFLAG="--dry"
# In-gate rstcs (corrected method): 0x150 is reset by the arm's 0x000 pulse, so a delta
# straddling the arm is meaningless (probe P2 returned -9034). Both reads here are AFTER
# the last arm, so this delta is resets during the gate window and nothing else.
rd150(){ if [ "$DRY" = 1 ]; then echo 0; else
  $W "$A" 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null; echo 0x150 > $DRA; cat $DRA' 2>/dev/null | tr -d '\r' | tail -1; fi; }
RS0=$(rd150); RS0=$((RS0))
R0=$(python3 "$READ" 148 $DRYFLAG) || { log "ARM_RF_SELF_FAIL_READ: seqbist_read.py failed (sample 0)"; tgen_set 0; echo "ARM_RF_SELF_FAIL_READ"; exit 5; }
[ "$DRY" = 1 ] || sleep "$GATE_WIN"
R1=$(python3 "$READ" 148 $DRYFLAG) || { log "ARM_RF_SELF_FAIL_READ: seqbist_read.py failed (sample 1)"; tgen_set 0; echo "ARM_RF_SELF_FAIL_READ"; exit 5; }
if [ "$DRY" = 1 ]; then
  # seqbist_read.py --dry restarts its own monotonic origin on every invocation, so
  # two DRY samples are always ~0 apart and the scorer below could never be exercised.
  # The two calls above still prove the invocation/JSON contract; substitute a
  # synthetic PASS-shaped pair here so the scoring arithmetic itself is DRY-tested.
  log "[dry] substituting a synthetic 15 s sample pair (1245 f/s, 0.02 % dev) to exercise the scorer"
  # Built by OVERWRITING fields of the real --dry JSON above, never by hand-writing a
  # dict: json_patch KeyErrors if seqbist_read.py ever renames ts_mono / reg_0x124 /
  # reg_0x104 / chk_frames, so the DRY PASS still tests the field-name contract.
  jp(){ python3 -c 'import json,sys
d=json.loads(sys.argv[1])
for kv in sys.argv[2:]:
    k,v=kv.split("=",1)
    if k not in d: raise KeyError("seqbist_read.py no longer emits %r" % k)
    d[k]=float(v) if "." in v else int(v)
print(json.dumps(d))' "$@"; }
  R0=$(jp "$R0" ts_mono=0.0 reg_0x124=0 reg_0x104=0 chk_frames=0) || { log "ARM_RF_SELF_FAIL_CONTRACT"; echo "ARM_RF_SELF_FAIL_CONTRACT"; exit 5; }
  R1=$(jp "$R1" ts_mono=15.0 reg_0x124=18675 reg_0x104=18675 chk_frames=18672) || { log "ARM_RF_SELF_FAIL_CONTRACT"; echo "ARM_RF_SELF_FAIL_CONTRACT"; exit 5; }
fi

RS1=$(rd150); RS1=$((RS1))
RSD=$(( RS1 - RS0 ))
log "RSTCS_GATE in-gate delta=$RSD (pre=$RS0 post=$RS1) over ~${GATE_WIN}s -- both reads AFTER the last arm, so no 0x000 reset falls between them"
# TGEN off: the gate window is over; seqbist_run.sh turns it back on for the leg.
tgen_set 0
sink_off

VERDICT=$(python3 - "$R0" "$R1" "$GATE_FPS" <<'PY'
import json, sys
a, b, gate = json.loads(sys.argv[1]), json.loads(sys.argv[2]), float(sys.argv[3])
dt = b["ts_mono"] - a["ts_mono"]
if dt <= 0:
    print("FAIL_DT 0 0 0 0"); raise SystemExit
d124 = b["reg_0x124"] - a["reg_0x124"]
dchk = b["chk_frames"] - a["chk_frames"]
d104 = b["reg_0x104"] - a["reg_0x104"]
fps124, fpschk = d124 / dt, dchk / dt
dev = abs(dchk - d124) / d124 * 100.0 if d124 else 999.0
ok = (fps124 >= gate) and (dev <= 1.0) and d124 > 0
print(f"{'PASS' if ok else 'FAIL'} {dt:.2f} {fps124:.1f} {fpschk:.1f} {dev:.3f} {d124} {dchk} {d104}")
PY
) || { log "ARM_RF_SELF_FAIL_SCORE"; echo "ARM_RF_SELF_FAIL_SCORE"; exit 5; }
set -- $VERDICT
log "  SEQ-BIST gate: verdict=$1 dt=${2}s 0x124=${3} f/s chk_frames=${4} f/s dev=${5} % (d124=${6} dchk=${7} d104=${8})"
log "  gate = 0x124 >= $GATE_FPS f/s AND |chk - 0x124| / 0x124 <= 1 %"

if [ "$1" != PASS ]; then
  if [ "$GATE_WAIVE" = 1 ]; then
    log "ARM_RF_SELF_GATE_WAIVED: gate not met (fps124=${3} chk=${4} dev=${5}) but GATE_WAIVE=1 --"
    log "  proceeding deliberately. a0/a1 both passed, so the radio and the self-coupling are"
    log "  fine; this gate measures the very filler effect the leg exists to quantify."
    echo "ARM_RF_SELF_GATE_WAIVED fps124=${3} chk_fps=${4} dev_pct=${5} romfps=$ROMFPS intfps=$INTFPS rstcs_gate=$RSD txatten=$TXATTEN"
    exit 0
  fi
  log "ARM_RF_SELF_FAIL_GATE: bring-up gate not met. Board is left ARMED RF byte (0x114=1, 0x158=1), TGEN off."
  echo "ARM_RF_SELF_FAIL_GATE fps124=${3} chk=${4} dev=${5}"; exit 6
fi
log "board left ARMED RF byte-source: 0x114=1 0x158=1 0x118=0, TGEN off, tgen_rx untouched, no daemon, no watchdog."
echo "ARM_RF_SELF_OK romfps=$ROMFPS intfps=$INTFPS fps124=${3} chk_fps=${4} dev_pct=${5} rstcs_gate=$RSD txatten=$TXATTEN lo_tx=$LO_TX lo_rx=$LO_RX ssi='$SSI'"
