#!/usr/bin/env python3
"""recovery_windows.py -- the ONE reader for capture_r3.sh's `recovery.txt`
(RXFIX Task 44: a mid-capture receiver collapse that the harness RECOVERED).

WHY THIS FILE EXISTS
--------------------
capture_r3.sh's step-7 stall watchdog used to do exactly one thing with a
mid-window delivery flatline: abort the leg (`CAPTURE_ABORTED_WEDGED`, exit 3).
Roughly 3 legs in 10 die that way.  With `MID_RECOVER=1` the harness instead
issues an RX-only double-tap re-arm, waits a BOUNDED time for delivery to come
back, and -- if it does -- carries on with the window.

A recovery is a PERTURBATION, not a repair of the measurement.  The interval
around it (the collapse, the re-arm, and a settle after it) is NOT the same
measurement as a clean leg's, so it must be dropped from BOTH the numerator and
the denominator of every rate the leg is scored on -- never counted as loss, and
never silently pooled with clean legs.  capture_r3.sh records each perturbed
interval in `recovery.txt` NEXT TO frames.bin; this module is what the scoring
tools use to honour it without a human having to notice the file.

Honoured by:
  * ops/accept_analyze.py      -- PER / bins / lag-33, scored per SEGMENT
  * ops/comb/comb_period_ms.py -- via ops/comb/common.py:loss_slot_trains
  * ops/comb/common.py         -- read_frames() prints a NOTICE for every
                                      other comb tool, which does NOT exclude

FILE FORMAT (written by capture_r3.sh, one line per recovery attempt)
---------------------------------------------------------------------
    RECOVERY_SCHEMA 1
    RECOVERY_EVENT idx=1 outcome=recovered detect_board_s=<epoch> ...
                   excl_start_s=<epoch> excl_end_s=<epoch> ...

`excl_start_s` / `excl_end_s` are the RX BOARD's CLOCK_REALTIME in seconds --
the same clock frames.bin's `t_real_ns` field is on (capture_r3.sh takes them
with `date` ON THE BOARD, exactly as it does for ROTATE_RX/USR1_RX).  They are
whole seconds not because the boards cannot do better -- both resolve `date` to
coreutils and print full nanoseconds [silicon, progress.md 2026-09-06 16:4x] --
but because they do not need to be: capture_r3.sh pads the start by a 2 s guard
and the end by a 15 s settle, so a 1 s truncation cannot move either bound out
of the perturbed region, and integer seconds keep the shell arithmetic that
produces them exact.

Every line is parsed by key, so extra fields may be added later without
breaking older readers, and an unparseable line is REPORTED (warnings), never
silently dropped: a leg whose recovery record cannot be read must not be
scored as if it had never been perturbed.

ENV
---
  QPSK_RECOVERY_IGNORE=1   ignore recovery.txt entirely -- the A/B control.
                           Scoring the same frames.bin with and without it must
                           differ by exactly the excluded gap; that is the
                           wiring test in task-44-brief.md.
  QPSK_RECOVERY_FILE=PATH  read this file instead of the sibling recovery.txt.
"""
import os
import sys

import numpy as np

RECOVERY_BASENAME = "recovery.txt"
EVENT_TAG = "RECOVERY_EVENT"
SCHEMA_TAG = "RECOVERY_SCHEMA"
SCHEMA_SUPPORTED = (1,)


def recovery_path_for(frames_path):
    """The recovery.txt that governs `frames_path` (env override wins)."""
    env = os.environ.get("QPSK_RECOVERY_FILE")
    if env:
        return env
    return os.path.join(os.path.dirname(os.path.abspath(frames_path)),
                        RECOVERY_BASENAME)


def _kv(line):
    out = {}
    for tok in line.split()[1:]:
        if "=" in tok:
            k, v = tok.split("=", 1)
            out[k] = v
    return out


def load_recovery(frames_path):
    """Parse the recovery record governing `frames_path`.

    Returns dict(path, present, events, warnings, excluded_s).  `events` is a
    list of dicts with float `excl_start_s` / `excl_end_s` (board
    CLOCK_REALTIME seconds) plus whatever else the line carried.  Missing file
    -> present=False, events=[]: the ordinary, unperturbed leg, and every
    caller then behaves exactly as it did before this module existed.
    """
    path = recovery_path_for(frames_path)
    out = dict(path=path, present=False, events=[], warnings=[], excluded_s=0.0)
    if os.environ.get("QPSK_RECOVERY_IGNORE") == "1":
        out["ignored"] = True
        return out
    if not os.path.exists(path):
        return out
    out["present"] = True
    try:
        with open(path) as f:
            lines = f.read().splitlines()
    except OSError as e:                                   # unreadable != absent
        out["warnings"].append(f"{path}: cannot read ({e})")
        return out
    for ln in lines:
        s = ln.strip()
        if not s or s.startswith("#"):
            continue
        if s.startswith(SCHEMA_TAG):
            tok = s.split()
            try:
                ver = int(tok[1])
            except (IndexError, ValueError):
                out["warnings"].append(f"{path}: unparseable {SCHEMA_TAG} line: {s!r}")
                continue
            if ver not in SCHEMA_SUPPORTED:
                out["warnings"].append(
                    f"{path}: {SCHEMA_TAG} {ver} is newer than this reader "
                    f"(supports {SCHEMA_SUPPORTED}); fields may be missing")
            continue
        if not s.startswith(EVENT_TAG):
            continue
        kv = _kv(s)
        try:
            a = float(kv["excl_start_s"])
            b = float(kv["excl_end_s"])
        except (KeyError, ValueError):
            out["warnings"].append(
                f"{path}: {EVENT_TAG} without usable excl_start_s/excl_end_s: {s!r}")
            continue
        if not b > a:
            out["warnings"].append(
                f"{path}: {EVENT_TAG} with excl_end_s <= excl_start_s ({a} .. {b}) -- dropped")
            continue
        ev = dict(kv)
        ev["excl_start_s"] = a
        ev["excl_end_s"] = b
        ev["excl_start_ns"] = int(a * 1e9)
        ev["excl_end_ns"] = int(b * 1e9)
        out["events"].append(ev)
    out["events"].sort(key=lambda e: e["excl_start_s"])
    out["excluded_s"] = float(sum(e["excl_end_s"] - e["excl_start_s"] for e in out["events"]))
    return out


def keep_mask(t_real_ns, events):
    """True where a frame is OUTSIDE every perturbed interval.

    `t_real_ns` is frames.bin's own t_real_ns for the records being scored.
    With no events this is all-True and every caller reduces to its previous
    arithmetic exactly.
    """
    t = np.asarray(t_real_ns, dtype=np.int64)
    keep = np.ones(t.shape, dtype=bool)
    for e in events:
        keep &= ~((t >= e["excl_start_ns"]) & (t <= e["excl_end_ns"]))
    return keep


def segments_from_mask(keep):
    """Contiguous runs of True in `keep`, as [start, stop) index pairs.

    One all-True mask gives exactly one segment spanning everything, which is
    why the segmented scorers stay byte-identical on an unperturbed leg.
    """
    keep = np.asarray(keep, dtype=bool)
    if keep.size == 0:
        return []
    idx = np.flatnonzero(keep)
    if idx.size == 0:
        return []
    brk = np.flatnonzero(np.diff(idx) > 1)
    starts = np.concatenate(([idx[0]], idx[brk + 1]))
    stops = np.concatenate((idx[brk], [idx[-1]])) + 1
    return [(int(a), int(b)) for a, b in zip(starts, stops)]


def describe(rec):
    """One human line for a loaded record, or '' when there is nothing to say."""
    if not rec.get("events"):
        return ""
    outcomes = {}
    for e in rec["events"]:
        o = e.get("outcome", "?")
        outcomes[o] = outcomes.get(o, 0) + 1
    what = " ".join(f"{k}x{v}" for k, v in sorted(outcomes.items()))
    return (f"RECOVERED LEG: {len(rec['events'])} mid-window recovery interval(s), "
            f"{rec['excluded_s']:.1f} s EXCLUDED from numerator and denominator "
            f"[{what}]  ({rec['path']})")


def warn_to_stderr(rec, prefix=""):
    """Print the description and any parse warnings on stderr (never stdout:
    stdout is what the campaign diffs between legs)."""
    d = describe(rec)
    if d:
        print(f"{prefix}{d}", file=sys.stderr)
    for w in rec.get("warnings", []):
        print(f"{prefix}RECOVERY-RECORD WARNING: {w}", file=sys.stderr)


def notice_for_unaware_tool(frames_path, tool=""):
    """Loud stderr NOTICE for a tool that reads a frames.bin governed by a
    recovery record but does NOT exclude it.  Called from
    ops/comb/common.py:read_frames, so every comb tool surfaces the fact
    for free.  Silent (and a no-op) when there is no recovery.txt, i.e. on
    every leg the campaign has ever scored to date."""
    rec = load_recovery(frames_path)
    if not rec.get("events"):
        for w in rec.get("warnings", []):
            print(f"RECOVERY-RECORD WARNING: {w}", file=sys.stderr)
        return rec
    print(f"NOTICE {tool}{'' if not tool else ': '}{describe(rec)}", file=sys.stderr)
    print("NOTICE   tools that honour it: accept_analyze.py, comb/comb_period_ms.py.",
          file=sys.stderr)
    print("NOTICE   any other tool reading this capture is scoring the perturbed "
          "interval as ordinary loss.", file=sys.stderr)
    for w in rec.get("warnings", []):
        print(f"RECOVERY-RECORD WARNING: {w}", file=sys.stderr)
    return rec


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("usage: recovery_windows.py <frames.bin|recovery.txt> [...]")
    for p in sys.argv[1:]:
        r = load_recovery(p)
        print(f"=== {p}")
        print(f"  record: {r['path']} present={r['present']} events={len(r['events'])} "
              f"excluded={r['excluded_s']:.1f}s")
        for e in r["events"]:
            print(f"  event idx={e.get('idx', '?')} outcome={e.get('outcome', '?')} "
                  f"[{e['excl_start_s']:.0f}, {e['excl_end_s']:.0f}] "
                  f"= {e['excl_end_s'] - e['excl_start_s']:.1f}s")
        for w in r["warnings"]:
            print(f"  WARNING: {w}")
