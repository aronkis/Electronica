#!/bin/bash
# sel11_preflight_go.sh -- T0c/P1 preflight (happy-bubbling-owl): before spending a
# 512 MiB DDRCAP window, take an 8 MiB sel11 (Transmitter_scramBit, the FABRIC
# scrambler -- WHITEN=0 is the HOST whitener, a different thing) capture on 148's
# CURRENT arm and confirm the bit-domain word packer (ddrcap_inject.py Sec 4.3: 16
# successive valid bits, MSB first, one 16-bit record per word, I=bitword Q=0) is
# actually carrying frame-header bytes 0x51 0x4B at a repeating cadence.
#
# 8 MiB target bytes -> SZ (ddrcap2_capture.sh's -s sample count) = 8 MiB / 4 B per
# complex sample = 2097152 (ddrcap2_capture.sh already checks GOT>=SZ*4*9/10, so this
# SZ produces the 8 MiB file directly, same arithmetic as its own 512 MiB default).
#
# Also runs ddrcap2_txmark_scan.py --fullrate on the capture to report what
# ddrcap_mark_fec (ch2 bit14, the TX-frame-start marker riding every selector) is
# wired to on this arm -- its own positive/negative controls are reused as-is.
#
# DRY=1 (default): ddrcap2_capture.sh is NEVER invoked for real (no DRY gate, would
# reach ssh/scp); this wrapper fabricates an 8 MiB sel11-shaped capture (I=packed
# 0x514B-bearing bitstream at a synthetic period, Q=0, ch2/ch3 markers set at the same
# period) so the marker-cadence checker and ddrcap2_txmark_scan.py both run for real
# against real bytes, with zero board contact.
set -u
D=$(cd "$(dirname "$0")" && pwd)          # two_jup/comb
TJ=$(cd "$D/.." && pwd)                   # two_jup
DRY=${DRY:-1}
SEL=11
SZ=${SZ:-2097152}
BRD=${BRD:-10.0.0.148}

TS=$(date +%Y%m%d_%H%M%S)
OUT=${OUT:-$D/runs/${TS}_sel11_preflight}
mkdir -p "$OUT"
log(){ echo "$(date -Is) $*" | tee -a "$OUT/run.log"; }

CAPFILE="$OUT/sel11_preflight.bin"
log "sel=$SEL sz=$SZ (8 MiB target) board=$BRD dry=$DRY -> $OUT"

if [ "$DRY" = 1 ]; then
  log "[dry] $TJ/ddrcap2_capture.sh $SEL sel11_preflight (on $BRD, current arm)"
  python3 - "$CAPFILE" "$SZ" <<'PY'
import sys, numpy as np
path, sz = sys.argv[1], int(sys.argv[2])
nrec = sz // 2          # ddrcap2_capture.sh arithmetic: bytes = SZ*4, record = 8 B
period_words = 512      # synthetic "air frame" period, in 16-bit words
rng = np.random.default_rng(1234)
I = (rng.integers(0, 65536, size=nrec, dtype=np.uint32)).astype('<u2')
ch2 = np.zeros(nrec, dtype='<u2'); ch3 = np.zeros(nrec, dtype='<u2')
# stamp a "0x51 0x4B" 16-bit header word at every period_words-th record, and a
# mark_fec pulse (ch2 bit14) MARK_LEAD words before it (the marker is expected to
# precede the header it announces).
MARK_LEAD = 3
hdr_word = (0x51 << 8) | 0x4B
for start in range(0, nrec - 1, period_words):
    I[start] = hdr_word
    lead = start - MARK_LEAD
    if lead >= 0:
        ch2[lead] = np.uint16(ch2[lead] | (1 << 14))
Q = np.zeros(nrec, dtype='<i2')
out = np.zeros((nrec, 4), dtype='<i2')
out[:, 0] = I.astype('<i2'); out[:, 1] = Q; out[:, 2] = ch2.astype('<i2'); out[:, 3] = ch3.astype('<i2')
out.tofile(path)
print(f"[dry] fabricated {nrec} sel11 records ({out.nbytes} bytes), header period={period_words} words, mark_lead={MARK_LEAD}")
PY
  CAP_PRE=BCF94856; CAP_POST=BCF94856; CAP_EXIT=0
else
  OUT="$OUT" B="$BRD" SZ="$SZ" "$TJ/ddrcap2_capture.sh" "$SEL" sel11_preflight > "$OUT/ddrcap2_capture.log" 2>&1
  CAP_EXIT=$?
  # ddrcap2_capture.sh names its own output $OUT/<name>.bin, which is already
  # $CAPFILE given the OUT/NAME env passed above -- no copy needed (task-3-fix1
  # minor: the old `cp "$OUT/sel11_preflight.bin" "$CAPFILE"` line was a no-op
  # self-copy since both paths are identical).
  LINE=$(grep -m1 "^sel11_preflight sel=$SEL" "$OUT/meta.txt" 2>/dev/null)
  CAP_PRE=$(echo "$LINE" | grep -oE 'pre=[0-9A-Fa-f]+' | cut -d= -f2)
  CAP_POST=$(echo "$LINE" | grep -oE 'post=[0-9A-Fa-f]+' | cut -d= -f2)
fi

# ---- marker-cadence check: reconstruct the continuous bit-domain byte stream from the
# packed 16-bit words (I column, MSB-first per ddrcap_inject.py Sec 4.3) and find every
# occurrence of 0x51 0x4B, reporting the count and the modal offset from the nearest
# preceding mark_fec (ch2 bit14) pulse. ----
python3 - "$CAPFILE" "$OUT/marker_check.json" <<'PY'
import sys, json
import numpy as np

path, outpath = sys.argv[1], sys.argv[2]
a = np.fromfile(path, dtype='<i2')
a = a[:(len(a)//4)*4].reshape(-1, 4)
I = a[:, 0].astype(np.uint16)
ch2 = a[:, 2].astype(np.uint16)
mark_fec_rec = np.nonzero((ch2 >> 14) & 1)[0]

# each record's I value IS the packed 16-bit word (MSB-first); concatenate to bytes.
bits = np.unpackbits(I[:, None].view(np.uint8)[:, ::-1], axis=1).reshape(-1)  # big-endian 16 bits/record
nbytes = len(bits) // 8
byte_stream = np.packbits(bits[:nbytes*8]).astype(np.uint8)

pat = np.array([0x51, 0x4B], dtype=np.uint8)
hits = []
for i in range(len(byte_stream) - 1):
    if byte_stream[i] == pat[0] and byte_stream[i+1] == pat[1]:
        hits.append(i)
hits = np.array(hits, dtype=np.int64)

spacings = np.diff(hits) if len(hits) > 1 else np.array([], dtype=np.int64)
modal_spacing = int(np.bincount(spacings).argmax()) if len(spacings) else None

# marker record -> bit position (start of its record's 16-bit word)
mark_bitpos = mark_fec_rec.astype(np.int64) * 16
offsets = []
for h in hits:
    hbit = h * 8
    prior = mark_bitpos[mark_bitpos <= hbit]
    if len(prior):
        offsets.append(int(hbit - prior[-1]))
modal_offset = int(np.bincount(offsets).argmax()) if offsets else None

result = {
    'records': int(len(a)),
    'mark_fec_pulses': int(len(mark_fec_rec)),
    'header_hits': int(len(hits)),
    'modal_spacing_bytes': modal_spacing,
    'modal_offset_from_marker_bits': modal_offset,
    'n_offsets_sampled': len(offsets),
}
json.dump(result, open(outpath, 'w'), indent=1)
print(json.dumps(result, indent=1))
PY

# ---- ddrcap_mark_fec wiring report: ddrcap2_txmark_scan.py --fullrate ----
python3 "$TJ/ddrcap2_txmark_scan.py" --fullrate "$CAPFILE" --out "$OUT/txmark_scan.json" > "$OUT/txmark_scan.log" 2>&1
TXMARK_RC=$?
log "ddrcap2_txmark_scan.py --fullrate exit=$TXMARK_RC (see $OUT/txmark_scan.json)"

HITS=$(python3 -c "import json;print(json.load(open('$OUT/marker_check.json'))['header_hits'])" 2>/dev/null || echo 0)
MODAL=$(python3 -c "import json;print(json.load(open('$OUT/marker_check.json'))['modal_offset_from_marker_bits'])" 2>/dev/null || echo None)

{
  echo "sel=11 sz=$SZ board=$BRD dry=$DRY"
  echo "capture_exit=$CAP_EXIT"
  echo "pre_capTAP=${CAP_PRE:-} post_capTAP=${CAP_POST:-} (need BCF94856 both)"
  echo "header_hits=$HITS modal_offset_from_marker_bits=$MODAL"
  echo "txmark_scan_exit=$TXMARK_RC"
  echo "ts=$(date -Is)"
} >> "$OUT/meta.txt"   # task-3-fix1 I-3: append, don't truncate ddrcap2_capture.sh's own provenance line

cat "$OUT/meta.txt"
echo "SEL11_PREFLIGHT_DONE $OUT header_hits=$HITS"
