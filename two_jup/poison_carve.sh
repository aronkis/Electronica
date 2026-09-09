#!/bin/sh
# poison_carve.sh -- RX S2MM carve poison gate (reusable carve-validity tooling).
#
# WHY THIS EXISTS (the stale-DDR lesson, task-TRANSFORM):
#   A byte-plane carve was analyzed for a full multi-task chain as if it were freshly
#   S2MM-delivered decode output. It was actually STALE DDR: leftover bytes of a prior
#   K5 -B loopback reference packet (pn9 seed 0x1A5), matched byte-exact. The S2MM had
#   written only a few fresh bytes per slice over an untouched stale buffer, and the
#   "structured constant columns" everyone chased were prior-test residue, not live
#   decode. This gate makes that failure impossible to repeat: poison the RX carve to a
#   unique tag BEFORE arming, so any post-run word still == tag is provably UNTOUCHED
#   (S2MM never wrote it) and any word that changed is provably FRESH this run.
#
# HARD SAFETY BAN (the /dev/mem incident, task-POISON):
#   NEVER use `dd` on /dev/mem in EITHER direction on these boards. This busybox `dd`
#   services skip=/seek= on the /dev/mem char device by SEQUENTIAL read/write FROM
#   ADDRESS 0 (not lseek): `dd if=/dev/mem skip=BIG` read ~2 GB through MMIO and wedged
#   board 146 (kernel hang, needed a power cycle). The write form is worse (writes over
#   the live kernel from addr 0). Poison ONLY with `busybox devmem ADDR 64 TAG`, which
#   mmaps the single target page -- reads AND writes the tag consistently (LE both ways).
#
# Layout (deployed 2 MB carve image, QPSK_CARVE_2MB; qpsk_hw.h + qpsk_tun.c):
#   TUN_RX_BUF_PHYS = 0x7FE20000. S2MM writes packets at pkt_bytes = 1528 B (0x5F8)
#   stride, 191 words/slice. -M32 => rx_arm carve_zeroes span*pkt_bytes = 32*1528 =
#   0xBF00 of the fill area before EACH transfer (so within a USED area the pre-S2MM
#   baseline is ZERO, not poison -- poison survives only in NEVER-armed areas/slack).
#   DOUBLE-BUFFER area stride = RX_MULTI_MAX*SLOT_BYTES = 64*2048 = 0x20000 (NOT 0xBF00;
#   qpsk_tun.c rx_area_phys). area0 @ 0x7FE20000, area1 @ 0x7FE40000. Scan slices at
#   1528 stride WITHIN each 0x20000 area (slicescan_146.sh's +0xBF00 "area1" was really
#   area0's unzeroed slack -- where TRANSFORM's stale -B ref bytes lived).
#
# Usage:  poison_carve.sh <board-ip> [nslices]     (default nslices=8 per area)
#         Arm/run the link AFTER this returns PASS; scan with slicescan_146.sh.

set -e
IP="$1"; NS="${2:-8}"
[ -n "$IP" ] || { echo "usage: $0 <board-ip> [nslices]"; exit 2; }
D=$(cd "$(dirname "$0")" && pwd)
TAG=0xDEADBEEFCAFEF00D

"$D/anyssh.sh" "$IP" "
  BASE=\$((0x7FE20000)); SL=1528; NW=191; NS=$NS; TAG=$TAG
  AREA=\$((0x20000))   # double-buffer stride = RX_MULTI_MAX*SLOT_BYTES = 64*2048
  echo \"poison: base=0x7FE20000 slice=1528B words=191 nslices=\$NS both-areas tag=$TAG\"
  # --- WRITE poison over first NS slices of BOTH areas (devmem only) ---
  for a in 0 1; do
    ab=\$((BASE + a*AREA)); s=0
    while [ \$s -lt \$NS ]; do
      so=\$((ab + s*SL)); w=0
      while [ \$w -lt \$NW ]; do
        busybox devmem \$((so + w*8)) 64 \$TAG
        w=\$((w+1))
      done
      s=\$((s+1))
    done
  done
  # --- VERIFY readback: every poisoned word must read back == TAG ---
  bad=0; tot=0
  for a in 0 1; do
    ab=\$((BASE + a*AREA)); s=0
    while [ \$s -lt \$NS ]; do
      so=\$((ab + s*SL)); w=0
      while [ \$w -lt \$NW ]; do
        v=\$(busybox devmem \$((so + w*8)) 64)
        tot=\$((tot+1))
        [ \"\$v\" = \"$TAG\" ] || bad=\$((bad+1))
        w=\$((w+1))
      done
      s=\$((s+1))
    done
  done
  echo \"poison verify: \$tot words, \$bad mismatches\"
  [ \$bad -eq 0 ] && echo 'POISON GATE: PASS' || echo 'POISON GATE: FAIL'
"
