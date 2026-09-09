#!/usr/bin/env python3
"""seqbist_read.py -- SEQ-BIST (happy-bubbling-owl T0d) counter snapshot tool.

One SSH round-trip (via anyssh.sh) per sample:
  1. read tgen_rx ctrl @0x9D410000, OR in bit3 (freeze), write back
  2. read modem 0x104 (packets_out) and 0x124 (cnt_frame_start) via
     /sys/kernel/debug/iio/iio:device0/direct_reg_access -- one read each
  3. for sel in 0..31: write tgen_rx gap word @0x9D410008 with bits[31:27]=sel,
     bits[26:0] preserved, then read tgen_rx_wit_gpio ch2 @0x9D450008
  4. restore the original gap word and ctrl word (clears freeze)

Prints ONE JSON line per sample with named fields (see NAMES below) plus a
wall-clock ISO timestamp and a monotonic timestamp.

--watch S (S >= 5): repeat every S seconds, forever (bound externally with
`timeout`, as seqbist_run.sh does).
--dry: fabricate plausible values with NO ssh invocation at all -- used for
end-to-end testing of the surrounding tools without board contact.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
TJ = os.path.dirname(HERE)                      # two_jup
ANYSSH = os.path.join(TJ, "anyssh.sh")

BOARD_IPS = {"148": "10.0.0.148", "146": "10.0.0.146"}

# cnt_mux32 slot order (interface contract, progress.md):
# 0-15 unchanged from cnt_mux16 (existing 148 image); 16-31 new checker slots.
SLOT_NAMES = [
    "acc_user", "frames", "crc_ok", "crc_fail", "magic_bad", "short", "orphan", "acc_beats",
    "ep_gt1k", "ep_gt2k", "ep_gt3k", "ep_gt6k", "ep_gt12k", "ep_gt25k", "max_len", "starve_clk",
    "chk_frames", "chk_good", "chk_garbage", "chk_crc_fail", "chk_lost_slots", "chk_gap_events",
    "chk_gap1", "chk_gap2", "chk_gap3plus", "chk_dup_or_reorder", "chk_last_seq", "chk_int_last",
    "chk_int_hist_lt30", "chk_int_32", "chk_int_33", "chk_int_other",
]
assert len(SLOT_NAMES) == 32

DM = 'DM=$(command -v devmem || echo "busybox devmem")'


def resolve_board(name):
    return BOARD_IPS.get(str(name), str(name))


def remote_script():
    # One ssh call, minimal register traffic: 2 ctrl rw, 2 modem reads,
    # 32 x (1 select-write + 1 counter-read), 2 restore writes.
    # RMW CONTRACT (fix round 2): every write to tgen_rx ctrl (0x9D410000) here is
    # read-modify-write -- CTRL is captured once, the freeze bit (bit3) is ORed in
    # and later the ORIGINAL CTRL is restored verbatim, so bit0 (tgen_rx enable,
    # must stay 0) and bit5 (tgen_mode) and every other live bit are preserved
    # across the freeze/unfreeze. A plain constant write here would clear en
    # and silently zero every counter mid-run.
    return f"""{DM}
DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
CTRL=$($DM 0x9D410000)
$DM 0x9D410000 32 $(( CTRL | 8 )) >/dev/null
echo 0x104 > $DRA; p104=$(cat $DRA)
echo 0x124 > $DRA; p124=$(cat $DRA)
GAPW=$($DM 0x9D410008)
BASE=$(( GAPW & 0x7FFFFFF ))
i=0; out=''
while [ $i -lt 32 ]; do
  $DM 0x9D410008 32 $(( (i << 27) | BASE )) >/dev/null
  v=$($DM 0x9D450008)
  out="$out s$i=$((v))"
  i=$((i+1))
done
$DM 0x9D410008 32 $GAPW >/dev/null
$DM 0x9D410000 32 $CTRL >/dev/null
echo "SEQREAD$out p104=$((p104)) p124=$((p124)) t=$(date +%s.%N)"
"""


def read_real(board_ip):
    cmd = [ANYSSH, board_ip, remote_script()]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    line = ""
    for ln in r.stdout.splitlines():
        if ln.startswith("SEQREAD"):
            line = ln
            break
    if not line:
        raise RuntimeError(f"seqbist_read: no SEQREAD line from {board_ip}: "
                            f"stdout={r.stdout!r} stderr={r.stderr!r}")
    kv = dict(re.findall(r"(\w+)=(\d+)", line))
    fields = {}
    for i, name in enumerate(SLOT_NAMES):
        fields[name] = int(kv.get(f"s{i}", 0))
    reg_0x104 = int(kv.get("p104", 0))
    reg_0x124 = int(kv.get("p124", 0))
    return fields, reg_0x104, reg_0x124


_DRY_T0 = time.monotonic()


def read_dry(skip_every, corrupt_every, fps=1245):
    e = max(0.0, time.monotonic() - _DRY_T0)
    chk_frames = int(fps * e)
    garbage = 0
    lost_slots = 0
    gap_events = 0
    gap1 = 0
    if skip_every and skip_every > 0:
        gap_events = chk_frames // skip_every
        lost_slots = gap_events  # skip_every advances seq by 2 -> one lost slot/event
        gap1 = gap_events
    elif corrupt_every and corrupt_every > 0:
        garbage = chk_frames // corrupt_every
    good = max(0, chk_frames - garbage - lost_slots)
    fields = {n: 0 for n in SLOT_NAMES}
    fields.update({
        "acc_user": chk_frames, "frames": chk_frames, "crc_ok": chk_frames,
        "crc_fail": 0, "magic_bad": garbage, "short": 0, "orphan": 0,
        "acc_beats": chk_frames * 191,
        "chk_frames": chk_frames, "chk_good": good, "chk_garbage": garbage,
        "chk_crc_fail": 0, "chk_lost_slots": lost_slots, "chk_gap_events": gap_events,
        "chk_gap1": gap1, "chk_gap2": 0, "chk_gap3plus": 0, "chk_dup_or_reorder": 0,
        "chk_last_seq": chk_frames, "chk_int_last": 32,
        "chk_int_hist_lt30": 0, "chk_int_32": gap_events, "chk_int_33": 0, "chk_int_other": 0,
    })
    reg_0x104 = chk_frames
    reg_0x124 = chk_frames
    return fields, reg_0x104, reg_0x124


def one_sample(board_arg, dry, skip_every, corrupt_every):
    ts_wall = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    ts_mono = time.monotonic()
    if dry:
        fields, reg_0x104, reg_0x124 = read_dry(skip_every, corrupt_every)
        board_ip = "dry-no-board"
    else:
        board_ip = resolve_board(board_arg)
        fields, reg_0x104, reg_0x124 = read_real(board_ip)
    out = {
        "ts_wall": ts_wall,
        "ts_mono": ts_mono,
        "board": board_ip,
        "reg_0x104": reg_0x104,
        "reg_0x124": reg_0x124,
    }
    out.update(fields)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("board", nargs="?", default=os.environ.get("BOARD", "148"))
    ap.add_argument("--watch", type=float, default=None,
                     help="repeat every S seconds (S >= 5), forever")
    ap.add_argument("--dry", action="store_true", default=os.environ.get("DRY", "0") == "1")
    ap.add_argument("--skip-every", type=int, default=int(os.environ.get("SKIP_EVERY", "0")),
                     help="DRY fabrication only: mirrors seqbist_run.sh SKIP_EVERY")
    ap.add_argument("--corrupt-every", type=int, default=int(os.environ.get("CORRUPT_EVERY", "0")),
                     help="DRY fabrication only: mirrors seqbist_run.sh CORRUPT_EVERY")
    args = ap.parse_args()

    if args.watch is not None and args.watch < 5:
        print("seqbist_read: --watch must be >= 5 seconds", file=sys.stderr)
        return 2

    def emit():
        rec = one_sample(args.board, args.dry, args.skip_every, args.corrupt_every)
        print(json.dumps(rec), flush=True)

    if args.watch is None:
        emit()
        return 0

    while True:
        emit()
        time.sleep(args.watch)


if __name__ == "__main__":
    sys.exit(main())
