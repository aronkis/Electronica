#!/bin/bash
# Characterise the documented rx-lpc IQ "ramp" on the CURRENT image, before
# committing a BD change that assumes the fault is ADC-side.
set -u
D=$(cd "$(dirname "$0")" && pwd)
. "$D/sim_repro/riglock.sh" 2>/dev/null || true
. "$D/agents/rigmutex.sh"
B=10.0.0.148
OUT=$D/rampprobe/$(date +%Y%m%d_%H%M%S); mkdir -p "$OUT"
rig_acquire ramp_probe 1800
rc=$?
if [ "$rc" -ne 0 ]; then echo "ACQUIRE FAILED rc=$rc"; exit "$rc"; fi
trap 'rig_release' EXIT

echo "== BOARD IMAGE ==" | tee "$OUT/image.txt"
"$D/anyssh.sh" $B 'md5sum /boot/BOOT.BIN | cut -c1-12' 2>/dev/null | tee -a "$OUT/image.txt"

echo "== IIO DEVICES ==" | tee "$OUT/devices.txt"
"$D/anyssh.sh" $B 'ls /sys/bus/iio/devices/ 2>/dev/null; for d in /sys/bus/iio/devices/iio:device*; do echo "$d: $(cat $d/name 2>/dev/null)"; done' 2>/dev/null | tee -a "$OUT/devices.txt"

echo "== iio_readdev availability ==" | tee "$OUT/tool.txt"
"$D/anyssh.sh" $B 'which iio_readdev iio_attr iio_info 2>&1' 2>/dev/null | tee -a "$OUT/tool.txt"

echo "== iio_info for candidate rx-lpc device ==" | tee -a "$OUT/tool.txt"
"$D/anyssh.sh" $B 'iio_info 2>&1 | grep -i -A5 "rx-lpc\|adrv9002"' 2>/dev/null | tee -a "$OUT/tool.txt"

# grab a short RX1 buffer via iio. xxd is NOT installed on this board image;
# use od (present) for signed-16-bit decode, 2 words/row = one I,Q pair.
"$D/anyssh.sh" $B 'cd /tmp && timeout 30 iio_readdev -b 4096 -s 65536 axi-adrv9002-rx-lpc voltage0_i voltage0_q > /tmp/rxdump.bin 2>/tmp/rxdump.err; echo EXIT=$?; cat /tmp/rxdump.err; ls -la /tmp/rxdump.bin' 2>/dev/null | tee "$OUT/rx1_capture.txt"
"$D/anyssh.sh" $B 'od -An -td2 -w4 /tmp/rxdump.bin | head -60' 2>/dev/null | tee "$OUT/rx1_raw.txt"

echo "RAMP_PROBE_DONE $OUT"
