#!/bin/bash
# replay_gate.sh <GATE_DIR> <TAG> -- REAL-IQ REPLAY gate (coordinator, Track N3
# blocker): S1B BIST does NOT cover the dirty-slx Symbol/Carrier Synchronizer
# regression, so each image's generated netlist must decode a real capture.
#
# Replays the canonical known-good hunt chunk (capture frames 270..339 + 8
# warm = 78 frames, rot=0, provenance-pinned slice) through the image's
# s1_rtl netlist via sim_byte_iq_perframe, scores per-frame CRC with
# score_frames.py (host frame contract), and requires >=95% CRC-good
# (>= 74/78). References on the SAME slice (HARNESS_AB 2026-08-13 rescore):
#   Jul-25 archive netlist @ its native cadence 4: 77 packets, 74/78 CRC-good
#     (the original "77/78" was the raw packets counter, NOT CRC-good — the
#     reference scores exactly the 74 threshold)
#   fsv2 lineage @ its native cadence 2: 75 packets, 71-72/78 CRC-good,
#     failing largely the SAME marginal frames (0, ~38, ~67, pair 53898-53900)
#   fsv2 lineage @ WRONG cadence 4: 5 packets, 0 CRC-good (the old gate drive)
set -e -o pipefail
G=${1:?usage: replay_gate.sh <gate dir> <tag>}
TAG=${2:?usage: replay_gate.sh <gate dir> <tag>}
K=/mnt/onetb/scratch/qpsk-jupiter-modem/jupiter_240k5_byte
VD=$G/s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback
export PATH=/usr/local/bin:/usr/bin:/bin
test -f "$VD/TxRxComposite.v" || { echo "REPLAY_GATE FATAL: no netlist at $VD"; exit 2; }
cd "$G/rtl_sim"
rm -rf obj_iq_perframe
# HARNESS_AB: single-source the driver from the kit (gate dirs carry stale copies)
cp -f "$K/rtl_sim/sim_byte_iq_perframe.cpp" .
verilator -O2 -Wno-fatal --cc wrap_byte.v -y "$VD" --exe sim_byte_iq_perframe.cpp \
  -Mdir obj_iq_perframe --top-module wrap_byte
make -s -C obj_iq_perframe -f Vwrap_byte.mk Vwrap_byte
CH=$K/rtl_sim/tap_replay_study/chunk_270_339_r0.iq
PROV=$K/rtl_sim/tap_replay_study/chunk_270_339_r0.prov
echo "REPLAY slice provenance: $(cat $PROV)"
NS=$(( $(stat -c%s "$CH") / 4 ))
# HARNESS_AB 2026-08-13 (two_jup/HARNESS_AB.md): drive cadence is a property of
# the NETLIST GENERATION, not a constant. Post-Jul-29 netlists (the R3 2x-rate
# restoration; includes the flashed e49c011b/64bb2476 lineage and fsv2/tmr146)
# consume one sample per enb_1_2_0 rail beat = 1-in-2 clk (matching the S1B
# driver sim_byte.cpp pacing and the hardware ingest); driving them at the old
# archive's cadence 4 double-beats every sample through the rail and collapses
# the sync loops (the 5/78 signature). The Jul-25/29 archive netlist is the
# OPPOSITE: it requires cadence 4 and fails at 2 (0/78). rstCS window and the
# scorer cadence scale with the drive. CAD is overridable for archive replays.
CAD=${CAD:-2}
RSTCS_END=$(( 2100 * CAD ))
./obj_iq_perframe/Vwrap_byte "$CH" $NS 0 $CAD $RSTCS_END 0 "$TAG" | tee ${TAG}_res.txt
python3 "$K/rtl_sim/tap_replay_study/score_frames.py" "$TAG" --cadence $CAD | tee ${TAG}_score.txt
NGOOD=$(awk -F, 'NR>1 && $NF==1' ${TAG}_verdict.csv | wc -l)
NTOT=78
echo "REPLAY_GATE frames_crc_good=$NGOOD / $NTOT (threshold 74)"
if [ "$NGOOD" -ge 74 ]; then echo "REPLAY_GATE: PASS"; else echo "REPLAY_GATE: FAIL"; exit 1; fi
