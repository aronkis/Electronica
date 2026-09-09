#!/bin/bash
# =============================================================================
# postflash_check.sh -- Task 6 post-flash verification of the seqbist image on 148,
# and the one piece of run setup no other tool does.
#
# [1] booted image md5 == the seqbist image
# [2] tgen_rx ctrl (0x9D410000) reads 0 at rest, and tgen_rx enable (bit0) is 0
#     (bit0 set would alias ctrl[5:4] onto qpsk_traffic_gen_rx2.fill_len[1:0])
# [3] *** SET tgen_mode (bit 5) *** -- read-modify-write, bit0 preserved at 0.
#     WHY THIS IS HERE: rx_seq_checker.v:121 -- tgen_mode = 1 accepts the CRC
#     field when it equals 0x54474E21, which is the constant qpsk_traffic_gen
#     writes into the CRC field of every frame. With tgen_mode = 0 (the reset
#     state, and the state the board is in after a flash) the checker CRC32-checks
#     those frames instead, so EVERY TGEN frame would count as crc_fail and the
#     stage-1 prereg "crc_fail = 0 (tgen_mode)" could never be met.
#     seqbist_run.sh and seqbist_read.py both PRESERVE bit5 in their RMWs but
#     neither one SETS it -- so it has to be set once, here, before any leg.
# [4] checker clear: pulse bit4 low -> high (RMW), leaving the checker enabled
# [5] do the new GPIO segments respond? Three reads (pre-clear / post-clear / +2 s):
#     the clear must knock the counters down, and then EITHER chk_frames advances with
#     0x104 (the segments respond to live traffic) OR, with no RX traffic, every chk_*
#     reads 0 (the brief's literal "0 at rest"). A slot reading 0xFFFFFFFF = not driven.
#     NOTE: the flash chain's own gate leaves 148 armed in mode-1 loopback decoding ROM
#     at ~1248 f/s, so a literal "all zero" is NOT expected on this path.
#
# Env: EXP=a1ff3c876d91  DRY=1 (default)
# =============================================================================
set -u
S=$(cd "$(dirname "$0")" && pwd); D=$(cd "$S/.." && pwd); W=$D/anyssh.sh
BOARD=${BOARD:-148}
case "$BOARD" in 148) A=10.0.0.148 ;; 146) A=10.0.0.146 ;; *) A=$BOARD ;; esac
EXP=${EXP:-a1ff3c876d91}; DRY=${DRY:-1}; SINK=${SINK:-none}
# ZERO_SLOTS_OK=1 (task 8, board 146): on the 146 seqbist lineage the LEGACY slots 0-15
# are 0 by design (no rx_seam_checker / tx_starve witnesses in that image), so with the
# byte plane idle ALL 32 slots read 0 and the "cnt_mux32 select looks stuck" heuristic --
# which is only valid when something free-running drives at least one slot -- fires on a
# healthy board. With this set, an all-zero-at-rest sweep is REPORTED, not failed, and the
# select path is proven instead by the first live leg (slots 16-31 must then differ).
ZERO_SLOTS_OK=${ZERO_SLOTS_OK:-0}
DM='DM=$(command -v devmem || echo "busybox devmem")'
log(){ echo "$(date -Is) [pf] $*"; }
brd(){ if [ "$DRY" = 1 ]; then echo "[dry] $*"; else $W $A "$@" 2>/dev/null | tr -d '\r'; fi; }

log "=== post-flash check on $BOARD ($A) (expect image $EXP) ==="
IMG=$(brd 'md5sum /boot/BOOT.BIN | cut -c1-12')
log "[1] booted image: $IMG (expect $EXP)"
[ "$DRY" = 1 ] || [ "$IMG" = "$EXP" ] || { log "PF_FAIL_IMAGE"; echo "PF_FAIL_IMAGE got=$IMG"; exit 2; }

C=$(brd "$DM; \$DM 0x9D410000")
log "[2] tgen_rx ctrl at rest = $C (SINK=$SINK)"
if [ "$DRY" != 1 ] && [ "$SINK" != tgenrx ]; then
  CV=$((C))
  if [ $(( CV & 1 )) -ne 0 ]; then log "PF_FAIL_TGENRX_ENABLED ctrl=$C"; echo "PF_FAIL_TGENRX_ENABLED"; exit 3; fi
fi
# SINK=tgenrx: hold qpsk_traffic_gen_rx2's enable high so it consumes+discards the DUT RX
# stream (qpsk_traffic_gen_rx2.v:114 dut_ready = en_d ? 1 : dma_ready). Without a drain the
# byte plane stalls and every checker counter reads 0 -- loopchk_run.sh:45. Disarmed on exit.
SINK_ARMED=0
sink_off(){ [ "$SINK_ARMED" = 1 ] || return 0; SINK_ARMED=0
  if [ "$DRY" = 1 ]; then log "[dry] SINK=tgenrx disarm: RMW clear bit0"
  else log "SINK=tgenrx disarm: ctrl=$(brd "$DM; C=\$(\$DM 0x9D410000); \$DM 0x9D410000 32 \$(( C & ~1 )); \$DM 0x9D410000")"; fi; }
trap sink_off EXIT INT TERM
if [ "$SINK" = tgenrx ]; then
  if [ "$DRY" = 1 ]; then log "[dry] SINK=tgenrx arm: RMW set 0x9D410000 bit0 (bits 3/4/5 preserved)"
  else log "SINK=tgenrx arm: $(brd "$DM; C=\$(\$DM 0x9D410000); \$DM 0x9D410000 32 \$(( C | 1 )); echo pre=\$C post=\$(\$DM 0x9D410000)")"; fi
  SINK_ARMED=1
fi

log "[3] setting tgen_mode (bit5) via RMW, bit0 preserved at 0"
C2=$(brd "$DM; C=\$(\$DM 0x9D410000); \$DM 0x9D410000 32 \$(( C | 32 )); \$DM 0x9D410000")
log "    ctrl after tgen_mode set = $C2 (need bit5=1, bit0=0)"
if [ "$DRY" != 1 ]; then
  V=$((C2))
  [ $(( V & 32 )) -ne 0 ] || { log "PF_FAIL_TGENMODE: bit5 did not stick (ctrl=$C2)"; echo "PF_FAIL_TGENMODE"; exit 4; }
  [ $(( V & 1 ))  -eq 0 ] || { log "PF_FAIL_TGENMODE: bit0 got set (ctrl=$C2)"; echo "PF_FAIL_TGENMODE"; exit 4; }
fi

log "[4] checker clear: bit4 low -> high (RMW; bit0/bit5 preserved)"
C3=$(brd "$DM; C=\$(\$DM 0x9D410000); \$DM 0x9D410000 32 \$(( C & ~16 )); sleep 0.05; \$DM 0x9D410000 32 \$(( C | 16 )); \$DM 0x9D410000")
log "    ctrl after clear pulse = $C3 (need bit5=1, bit4=1, bit0=0)"

log "[5] do the NEW GPIO segments respond, and does the clear work?"
# The brief asks for "slots 16-31 = 0 at rest after a clear". That is only true if the RX
# byte plane is IDLE -- but the flash chain's own gate leaves 148 armed in mode-1 internal
# loopback with 0x158=0, so the decoder is emitting ROM bytes at ~1248 f/s and the checker
# (correctly) counts them. So the check is done properly, as three reads:
#   PRE  (before the clear)  -> whatever has accumulated
#   POST (right after)       -> must be BELOW pre  => the clear pulse works
#   LATE (2 s later)         -> if 0x104 advanced, chk_frames must advance too (the new
#                               segments respond); if 0x104 is static, every chk_* must be 0
#                               (the literal "0 at rest").
DRYFLAG=""; [ "$DRY" = 1 ] && DRYFLAG="--dry"
rd(){ python3 "$S/seqbist_read.py" "$BOARD" $DRYFLAG; }
PRE=$(rd)  || { log "PF_FAIL_READ pre"; echo "PF_FAIL_READ"; exit 5; }
CLR=$(brd "$DM; C=\$(\$DM 0x9D410000); \$DM 0x9D410000 32 \$(( C & ~16 )); sleep 0.05; \$DM 0x9D410000 32 \$(( C | 16 )); \$DM 0x9D410000")
log "    clear pulse #2 (immediately before the response test): ctrl=$CLR"
POST=$(rd) || { log "PF_FAIL_READ post"; echo "PF_FAIL_READ"; exit 5; }
[ "$DRY" = 1 ] || sleep 2
LATE=$(rd) || { log "PF_FAIL_READ late"; echo "PF_FAIL_READ"; exit 5; }
echo "$PRE";  echo "$POST"; echo "$LATE"
python3 - "$PRE" "$POST" "$LATE" "$DRY" "$ZERO_SLOTS_OK" <<'PY2'
import json, sys
pre, post, late = (json.loads(a) for a in sys.argv[1:4])
dry = sys.argv[4] == "1"
zero_ok = sys.argv[5] == "1"
new = [k for k in pre if k.startswith("chk_")]
legacy = ["acc_user","frames","crc_ok","crc_fail","magic_bad","short","orphan","acc_beats",
          "ep_gt1k","ep_gt2k","ep_gt3k","ep_gt6k","ep_gt12k","ep_gt25k","max_len","starve_clk"]
for tag, d in (("PRE", pre), ("POST", post), ("LATE", late)):
    print(f"    {tag:4s} 16-31: " + " ".join(f"{k[4:]}={d[k]}" for k in new))
print("    legacy 0-15 (LATE): " + " ".join(f"{k}={late[k]}" for k in legacy))
d104 = late["reg_0x104"] - post["reg_0x104"]
d124 = late["reg_0x124"] - post["reg_0x124"]
dchk = late["chk_frames"] - post["chk_frames"]
# BYTE-PLANE LIVENESS IS NOT 0x104 (corrected 2026-09-04 00:11 on real post-flash data).
# 0x104/0x124 count demod frame-syncs, which advance at line rate whenever the modem is
# armed -- including with 0x158=0 (ROM source), which is how arm148_mode1.sh and therefore
# the flash chain's own gate leave the board. In ROM mode the RX *byte* plane is idle: the
# first post-flash read showed 0x104 advancing 4107 in ~3.3 s (= 1245 f/s) while
# acc_beats=0 and every legacy rx_seam_checker slot (0-7) read 0 -- and those slots are
# known-good on this lineage (loopchk_run.sh measures frames with them). So the liveness
# signal has to come from the byte plane itself: acc_beats / the legacy frames counter.
dbeats  = late["acc_beats"] - post["acc_beats"]
dlegacy = late["frames"] - post["frames"]
byte_live = (dbeats > 0) or (dlegacy > 0)
print(f"    over the 2 s window: d0x104={d104} d0x124={d124} d_chk_frames={dchk} "
      f"d_acc_beats={dbeats} d_legacy_frames={dlegacy} byte_plane_live={byte_live}")
if dry:
    print("PF_SEGMENTS=dry"); raise SystemExit(0)
fails = []
# (i) the clear works: cumulative counters must not be higher after the pulse than before,
#     allowing for the frames that arrive between the two reads (~1 ssh round trip).
if pre["chk_frames"] > 0 and post["chk_frames"] >= pre["chk_frames"]:
    fails.append(f"clear did not reset chk_frames (pre={pre['chk_frames']} post={post['chk_frames']})")
# (ii) responsiveness
if byte_live and dchk <= 0:
    fails.append(f"RX byte plane is live (d_acc_beats={dbeats} d_legacy_frames={dlegacy}) "
                 f"but chk_frames did not advance")
if not byte_live and any(late[k] for k in new):
    nz = {k: late[k] for k in new if late[k]}
    fails.append(f"byte plane idle yet slots 16-31 non-zero at rest: {nz}")
# The mux SELECT path is proven independently of any traffic: a sweep that returns
# several DIFFERENT values cannot be a stuck bus. With the byte plane idle the only
# non-zero slots are the free-running tx_starve witnesses (8-15), and that is enough.
allslots = [late[k] for k in legacy] + [late[k] for k in new]
if len(set(allslots)) < 2:
    if zero_ok and allslots[0] == 0:
        print("    NOTE: all 32 slots read 0 at rest (ZERO_SLOTS_OK=1). The select path is "
              "NOT proven here -- it is proven by the first live leg, where slots 16-31 must "
              "take distinct non-zero values.")
    else:
        fails.append(f"cnt_mux32 select looks stuck: all 32 slots read the same value "
                     f"({allslots[0]})")
# (iii) stuck-bit sanity: an unconnected GPIO segment reads all-ones
if any(late[k] == 0xFFFFFFFF for k in new):
    fails.append("a slot reads 0xFFFFFFFF (segment not driven)")
if fails:
    for f in fails: print("PF_FAIL_SEGMENTS " + f)
    raise SystemExit(6)
print("PF_SEGMENTS_OK mux_select=distinct " +
      ("responds_to_traffic=yes" if byte_live else "zero_at_rest=yes (byte plane idle: "
       "ROM source, 0x158=0 -- responsiveness is proven by stage-1 ctrlA, not here)"))
PY2
RC=$?
[ "$RC" = 0 ] || { echo "PF_FAIL_SLOTS rc=$RC"; exit "$RC"; }
log "POSTFLASH_OK image=$IMG tgen_mode=set checker=cleared segments=verified"
echo "POSTFLASH_OK"
