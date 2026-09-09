#!/usr/bin/env python3
"""w1_ctl.py -- RXFIX Task 10 Step 2: roll the three control read-sets produced by
`w1leg_go.sh MODE=ctrl` into ONE control table, with a verdict per tap.

  w1_ctl.py <run_dir>            # expects reads_pre/ reads_freeze/ reads_post/

The Step-2 rule this implements (task-10-brief.md): a zero on an edge counter is
only ever reported as "did not increment in <window>" TOGETHER with the occupancy
word from the same read, and "no holes" is claimed only if the counter also passed
the arm-transient control in the same session.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from w1_score import (CENSUS, EQ_TOL, M15, M16, M32, d15, d16, d32, decode,  # noqa: E402
                      SYM_PER_FRAME)


def load(d):
    p = os.path.join(d, "readings.jsonl")
    out = []
    if not os.path.exists(p):
        return out
    for ln in open(p):
        ln = ln.strip()
        if not ln:
            continue
        r = json.loads(ln)
        if r.get("dry") or r.get("error") or not r.get("words"):
            continue
        v = decode(r["words"])
        v["ts"] = r["ts"]
        v["freeze_effective"] = r.get("freeze_effective")
        v["r4b_moved"] = r.get("r4b_moved")
        v["aux_lag_s"] = r.get("aux_lag_s")
        aux = r.get("aux") or {}
        v["frames"] = int(aux["0x104"], 16) if "0x104" in aux else None
        out.append(v)
    return out


def main():
    run = sys.argv[1]
    pre, frz, post = (load(os.path.join(run, x)) for x in ("reads_pre", "reads_freeze", "reads_post"))
    L = []
    A = L.append
    A(f"=== W1 Step-2 control table (run {run}) ===")
    A(f"reads: pre={len(pre)} freeze-hold={len(frz)} post={len(post)}")
    A("")

    rows = []

    # ---- freeze path -------------------------------------------------------
    if frz:
        ok = frz[0]["freeze_effective"]
        rows.append(("freeze path (0x208 bit 4)",
                     "freeze held 10 s -> every one of the 8 word deltas exactly 0",
                     "PASS" if ok else "FAIL",
                     f"freeze_effective={ok} on the 10 s HOLD read "
                     f"(two frozen sweeps 10 s apart compared word for word)"))
    else:
        rows.append(("freeze path (0x208 bit 4)", "freeze held 10 s", "NO DATA", ""))

    # ---- census counters ---------------------------------------------------
    for setname, s in (("pre", pre), ("post", post)):
        if len(s) < 2:
            continue
        for i in range(1, len(s)):
            a, b = s[i - 1], s[i]
            dd = {c: d32(a[c], b[c]) for c in CENSUS}
            df = d32(a["frames"], b["frames"]) if a["frames"] is not None else None
            A(f"  [{setname} {i}] " + " ".join(f"{c}={dd[c]}" for c in CENSUS)
              + f"  d0x104={df}  occ={b['occ']} push={b['push_ptr']} pop={b['pop_ptr']}"
              + f"  poe={b['pop_on_empty']} pof={b['push_on_full']}")
    A("")

    allsets = [s for s in (pre, post) if len(s) >= 2]
    up = ["cSS", "cRH", "cCFC", "cCS", "cPD"]
    for c in CENSUS:
        vals, zero, adv = [], True, False
        for s in allsets:
            for i in range(1, len(s)):
                dv = d32(s[i - 1][c], s[i][c])
                vals.append(dv)
                if dv:
                    zero = False
                    adv = True
        if not vals:
            rows.append((c, "delta advances over 10 s", "NO DATA", ""))
            continue
        # equality against the other pre-discard stages, per interval (exact: one snapshot)
        eq = None
        if c in up:
            eq = True
            for s in allsets:
                for i in range(1, len(s)):
                    ref = d32(s[i - 1]["cSS"], s[i]["cSS"])
                    if abs(d32(s[i - 1][c], s[i][c]) - ref) > EQ_TOL:
                        eq = False
        if zero:
            v = "DEAD (excluded from the air-leg verdict)"
        elif c in up and eq is False:
            v = f"ADVANCES, but differs from cSS by > {EQ_TOL}"
        else:
            v = "PASS"
        note = f"deltas {vals}"
        if c == "cPC":
            note += "  (expected SHORT by 13/frame: sample_discard_controller guard drop)"
        rows.append((c, f"advances, and == the other pre-discard stages (within +-{EQ_TOL}; "
                     f"fixed pipeline offsets cancel, cCS jitters one beat)" if c in up
                     else "advances (12,320/frame, not 12,333)", v, note))

    # ---- witA occupancy / pointers ----------------------------------------
    occs, ptrs = [], set()
    for s in allsets:
        for r in s:
            occs.append(r["occ"])
            ptrs.add((r["push_ptr"], r["pop_ptr"]))
    if occs:
        rows.append(("witA occupancy", "nonzero and/or changing across the arm; constant after",
                     "PASS" if any(o != 0 for o in occs) or len(set(occs)) > 1 else "ALL ZERO",
                     f"occ values {sorted(set(occs))}"))
        rows.append(("witA pointers", "advance mod 32 between reads",
                     "PASS" if len(ptrs) > 1 else "STATIC",
                     f"{len(ptrs)} distinct (push,pop) pairs: {sorted(ptrs)[:6]}"))

    # ---- edge counters: the ARM TRANSIENT ---------------------------------
    if pre and post:
        p_last, q_first = pre[-1], post[0]
        d_poe = (q_first["pop_on_empty"] - p_last["pop_on_empty"]) % M16
        d_pof = (q_first["push_on_full"] - p_last["push_on_full"]) % M16
        cleared = q_first["pop_on_empty"] < p_last["pop_on_empty"]
        live = d_poe >= 1 or (cleared and q_first["pop_on_empty"] > 0)
        rows.append(("pop_on_empty (witB[15:0])",
                     "ARM TRANSIENT: cumulative jumps >= 1 across the re-arm "
                     "(or restarts from nonzero if it clears on reset)",
                     "PASS (LIVE)" if live else "FAIL (DEAD -- air leg cannot use it)",
                     f"pre-re-arm cumulative={p_last['pop_on_empty']}, "
                     f"post-re-arm cumulative={q_first['pop_on_empty']}, "
                     f"mod-2^16 jump={d_poe}, counter_cleared_on_reset={cleared}"))
        rows.append(("push_on_full (witB[31:16])",
                     "arm transient >= 1 IF acquisition overshoots (sim: 17). "
                     "A zero here is NOT a failure -- unexercised in sim (task-9 concern 2)",
                     "LIVE" if d_pof >= 1 or q_first["push_on_full"] > 0 else "NOT EXERCISED",
                     f"pre={p_last['push_on_full']}, post={q_first['push_on_full']}, jump={d_pof}"))

        # null in steady loopback (reads 2 and 3 of each set)
        nulls = []
        for s in allsets:
            for i in range(1, len(s)):
                nulls.append((d16(s[i - 1]["pop_on_empty"], s[i]["pop_on_empty"]),
                              d16(s[i - 1]["push_on_full"], s[i]["push_on_full"])))
        nz = [n for n in nulls if n != (0, 0)]
        rows.append(("edge counters NULL",
                     "steady loopback (one clock, drift 0): poe and pof deltas both 0",
                     "PASS" if not nz else "NOT MET",
                     f"per-interval (d_poe,d_pof) = {nulls}"))

    # ---- R4B: the ninth word (Task 13) --------------------------------------
    r4b_sets = [s for s in allsets if s and "r4b_raw" in s[0]]
    if r4b_sets:
        locked = [r["r4b_locked"] for s in r4b_sets for r in s]
        rows.append(("r4b_locked / r4b_armed (0x234[31])",
                     "1 after lock (eight pcEnd pulses since reset); armed == locked",
                     "PASS" if all(locked) else f"NOT ARMED on {locked.count(0)} reading(s)",
                     f"values {locked}"))

        d_opens, d_skips = [], []
        for s in r4b_sets:
            for i in range(1, len(s)):
                d_opens.append(d15(s[i - 1]["r4b_opens"], s[i]["r4b_opens"]))
                d_skips.append(d16(s[i - 1]["r4b_skips"], s[i]["r4b_skips"]))
        rows.append(("r4b_window_opens (0x234[14:0])",
                     "THE LIVENESS CONTROL under R4B: advances at the FRAME rate. A static "
                     "value means no pcEnd, so no skip could ever fire -- which is what "
                     "distinguishes 'steering idle because the ring is healthy' from "
                     "'steering dead'. 15-bit: wraps in ~26 s at ~1,250 f/s",
                     "PASS" if d_opens and all(d > 0 for d in d_opens) else "STATIC",
                     f"per-interval deltas {d_opens}"))
        cums = [r["r4b_skips"] for s in r4b_sets for r in s]
        rows.append(("r4b_skips (0x234[30:15])",
                     "advances over the first ~10 frames after lock, then FLAT (the ring "
                     "self-centres at 9/10 and the occ<=8 predicate goes false)",
                     "PASS (flat after the startup burst)" if d_skips and not any(d_skips)
                     else ("ADVANCING in steady loopback" if any(d_skips) else "NO DATA"),
                     f"cumulative {cums}; per-interval deltas {d_skips}"))

        occ_r4b = [r["occ"] for s in r4b_sets for r in s]
        rows.append(("witA occupancy after lock (R4B)",
                     "8-10 once the steering has self-centred the ring (was 0-1 on W1)",
                     "PASS" if all(8 <= o <= 10 for o in occ_r4b) else "OUT OF BAND",
                     f"occ values {sorted(set(occ_r4b))}"))

        moved = [r["r4b_moved"] for s in r4b_sets for r in s if r.get("r4b_moved") is not None]
        if moved:
            rows.append(("0x234 outside the freeze shadow",
                         "the ninth word ADVANCES between the two frozen sweeps -- it is one "
                         "word, coherent on a single AXI read, and deliberately not shadowed",
                         "PASS" if all(moved) else "DID NOT MOVE",
                         f"moved on {sum(1 for m in moved if m)}/{len(moved)} readings"))

    # ---- stuck-at ----------------------------------------------------------
    every = [r for s in allsets for r in s]
    if len(every) > 1:
        keys = ["witA_raw"] + CENSUS + (["r4b_raw"] if "r4b_raw" in every[0] else [])
        stuck = [k for k in keys if all(r[k] == every[0][k] for r in every)]
        rows.append((f"stuck-at sweep ({len(keys) + 1} words)",
                     "witA/witB, each census slot and (on a W1+R4B image) 0x234 differ "
                     "between at least two reads",
                     "PASS" if not stuck else f"STUCK: {','.join(stuck)}",
                     f"{len(every)} readings compared over {len(keys) + 1} words"))

    A("=== CONTROL TABLE ===")
    A(f"{'tap':<28} {'verdict':<38} control / evidence")
    A("-" * 118)
    for tap, ctl, verd, note in rows:
        A(f"{tap:<28} {verd:<38} {ctl}")
        if note:
            A(f"{'':<28} {'':<38} {note}")
    A("")
    dead = [r[0] for r in rows if "DEAD" in r[2] or "FAIL" in r[2] or "STUCK" in r[2]]
    A(f"TAPS FAILING THEIR CONTROL: {dead if dead else 'none'}")
    if dead:
        A("Per the brief, any counter that failed its Step-2 control is EXCLUDED from")
        A("P/F evaluation and the air leg is labelled PARTIAL.")
    print("\n".join(L))
    return 0


if __name__ == "__main__":
    sys.exit(main())
