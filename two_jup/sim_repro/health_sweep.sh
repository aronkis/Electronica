#!/usr/bin/env bash
# T1 dataset curation: run check_capture_health.py over every candidate capture
# and emit a CSV manifest row per file. Offline only -- touches no board.
# Usage: health_sweep.sh <out.csv>
set -u
ROOT=/mnt/onetb/scratch/qpsk-jupiter-modem
CHK=$ROOT/two_jup/check_capture_health.py
OUT=${1:?out.csv}

echo "path,dir,date,bytes,bw_mhz,env_corr,env_lag,verdict,meta_dir,has_frames,has_fslog,has_txlog" > "$OUT"

emit() {  # $1 = iq path
  local iq=$1 d meta dirfld="?" date bytes res bw env lag verdict hf=0 hs=0 ht=0
  d=$(dirname "$iq")
  [ -f "$d/meta.txt" ] && dirfld=$(grep -oE 'dir=[a-z]+' "$d/meta.txt" | head -1 | cut -d= -f2)
  date=$(stat -c %y "$iq" | cut -d' ' -f1)
  bytes=$(stat -c %s "$iq")
  [ -f "$d/frames.bin" ] && hf=1
  ls "$d"/fslog_*.bin >/dev/null 2>&1 && hs=1
  ls "$d"/txlog_*.bin >/dev/null 2>&1 && ht=1
  res=$(python3 "$CHK" "$iq" 2>&1)
  rc=$?
  bw=$(echo "$res" | grep -oE 'occupied BW *= *[0-9.]+' | grep -oE '[0-9.]+$')
  env=$(echo "$res" | grep -oE 'env periodicity *= *[0-9.]+' | grep -oE '[0-9.]+$')
  lag=$(echo "$res" | grep -oE 'at lag *[0-9]+' | grep -oE '[0-9]+$' | head -1)
  case $rc in 0) verdict=HEALTHY;; 1) verdict=DEGENERATE;; *) verdict=ERROR;; esac
  echo "$iq,$dirfld,$date,$bytes,${bw:-},${env:-},${lag:-},$verdict,$dirfld,$hf,$hs,$ht" >> "$OUT"
}

# every pair.iq in r3cap (skips restore_N automatically: they carry no IQ)
for iq in "$ROOT"/two_jup/r3cap/*/pair.iq "$ROOT"/two_jup/r3cap/*/*/pair.iq; do
  [ -f "$iq" ] && emit "$iq"
done
# prewedge + evmcap raw taps + floatgap refs + paired
for iq in "$ROOT"/two_jup/prewedge/*/*.iq \
          "$ROOT"/two_jup/evmcap/*/raw.iq \
          "$ROOT"/two_jup/floatgap_n3/*.iq \
          "$ROOT"/two_jup/paired/*.iq; do
  [ -f "$iq" ] && emit "$iq"
done
echo "SWEEP_DONE $(wc -l < "$OUT") rows" >> "$OUT"
