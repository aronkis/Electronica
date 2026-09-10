#!/usr/bin/env python3
"""Tests for accept_analyze.py's --burst-times option (RXFIX Task 23).

The repo's rule, stated in singles_cadence.py: "a scorer that has never caught a
planted fault is not trusted with a negative result." So every test here plants
bursts at KNOWN slots and times in a synthesized frames.bin and asserts recovery
-- onset seq, run length, count, and the time on both clocks.

It also pins the new interpolation against ops/comb/common.py's
interp_t_mono_ns(), which is the campaign's other implementation of the same
"a lost slot has no timestamp of its own" estimate: the two must agree to the
nanosecond on the same data, or the census and the burst CSV would be placing
the same event at two different times.
"""
import os
import struct
import subprocess
import sys
import tempfile
import unittest

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
TWO_JUP = os.path.dirname(HERE)
sys.path.insert(0, TWO_JUP)
sys.path.insert(0, os.path.join(TWO_JUP, "comb"))

import accept_analyze  # noqa: E402
from frame_taxonomy import DTYPE  # noqa: E402

FRAME_NS = 803_000          # 803 us/frame, the leg's fabric frame period
T_MONO0 = 887_314_868_017   # arbitrary board uptime, as on the R4B air leg
T_REAL0 = 1_788_567_624_902_465_000


def synth(path, n_slots=40_000, bursts=(), crc_bad_slots=(), seed=3):
    """Write a frames.bin with `n_slots` transmitted slots, one clean record per
    slot except where a burst deletes a run. bursts = [(onset_slot, run_len)].

    Deleted slots produce NO record at all -- that is exactly how a lost frame
    appears to the reconstruction (only crc_ok==1 host_seq place a slot).
    `crc_bad_slots` get a record with crc_ok==0: such a slot IS a loss (the
    frame did not arrive intact), so a crc-bad slot inside the live window must
    show up as a run of its own -- pinned by
    test_in_window_crc_fail_counts_as_a_loss.
    """
    del seed
    lost = np.zeros(n_slots, dtype=bool)
    for onset, ln in bursts:
        lost[onset:onset + ln] = True
    keep = np.flatnonzero(~lost)
    fr = np.zeros(keep.size, dtype=DTYPE)
    fr["host_seq"] = keep.astype(np.uint32)
    # time advances with the SLOT index, not the record index: a lost slot still
    # consumes air time, which is the whole reason interpolation is on seq.
    fr["t_mono_ns"] = (T_MONO0 + keep.astype(np.uint64) * FRAME_NS)
    fr["t_real_ns"] = (T_REAL0 + keep.astype(np.uint64) * FRAME_NS)
    fr["crc_ok"] = 1
    fr["reg_packets"] = keep.astype(np.uint32)
    for s in crc_bad_slots:
        hit = np.flatnonzero(keep == s)
        assert hit.size == 1, f"crc_bad_slot {s} collides with a planted burst"
        fr["crc_ok"][hit[0]] = 0
    with open(path, "wb") as f:
        fr.tofile(f)
    return fr


class TestBurstTimes(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="t23bt_")
        self.bin = os.path.join(self.tmp, "frames.bin")
        # onsets chosen past the 15 s settle (15 s / 803 us = slot 18,679) and
        # clear of each other, with the three run-length classes represented.
        self.bursts = [(25_000, 1), (28_000, 2), (30_500, 7), (33_000, 12)]
        # crc-bad records are parked BEFORE the 15 s settle so they cannot move
        # the in-window census; the in-window case has its own test below.
        synth(self.bin, bursts=self.bursts, crc_bad_slots=(1_000, 5_000, 9_000))

    def test_planted_bursts_are_recovered(self):
        r = accept_analyze.analyze(self.bin, burst_times=True)
        self.assertTrue(r["usable"])
        got = [(b["onset_seq"], b["run_len"]) for b in r["bursts"]]
        self.assertEqual(got, self.bursts,
                         "planted onsets/run lengths not recovered exactly")
        self.assertEqual(r["miss"], sum(l for _, l in self.bursts))

    def test_onset_times_match_the_slot_axis(self):
        r = accept_analyze.analyze(self.bin, burst_times=True)
        for b in r["bursts"]:
            want_mono = T_MONO0 + b["onset_seq"] * FRAME_NS
            want_real = T_REAL0 + b["onset_seq"] * FRAME_NS
            # interpolation between the two adjacent clean anchors is exact on a
            # uniform slot axis; allow one frame period of slack, no more.
            self.assertLessEqual(abs(b["t_mono_ns"] - want_mono), FRAME_NS,
                                 f"t_mono_ns off for seq {b['onset_seq']}")
            self.assertLessEqual(abs(b["t_real_ns"] - want_real), FRAME_NS,
                                 f"t_real_ns off for seq {b['onset_seq']}")
            self.assertAlmostEqual(b["t_s"], (b["t_mono_ns"] - T_MONO0) / 1e9,
                                   places=6)

    def test_agrees_with_comb_common_interp(self):
        """Pin the new estimate to ops/comb/common.py's own."""
        from common import interp_t_mono_ns, loss_slot_trains  # noqa: E402
        from frame_taxonomy import read_frames  # noqa: E402
        fr = read_frames(self.bin)
        lt = loss_slot_trains(fr)
        self.assertTrue(lt["usable"])
        r = accept_analyze.analyze(self.bin, burst_times=True)
        onsets = np.array([b["onset_seq"] for b in r["bursts"]], dtype=np.int64)
        mine = np.array([b["t_mono_ns"] for b in r["bursts"]], dtype=np.int64)
        theirs = interp_t_mono_ns(lt, onsets)
        self.assertTrue(np.array_equal(mine, theirs),
                        f"accept_analyze {mine} != comb/common {theirs}")

    def test_no_bursts_key_and_identical_numbers_when_off(self):
        """The option must be inert when not asked for -- the campaign compares
        PER across legs by re-running this tool, so the default path may not move."""
        off = accept_analyze.analyze(self.bin)
        on = accept_analyze.analyze(self.bin, burst_times=True)
        self.assertNotIn("bursts", off)
        for k in ("miss", "span", "bins", "live_end", "dur", "wedged", "usable"):
            self.assertEqual(off[k], on[k], f"{k} moved when --burst-times was on")

    def test_cli_writes_csv(self):
        out = os.path.join(self.tmp, "bursts.csv")
        p = subprocess.run(
            [sys.executable, os.path.join(TWO_JUP, "accept_analyze.py"),
             "--burst-times", out, self.bin],
            capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("burst times: 4 loss runs", p.stdout)
        with open(out) as f:
            lines = f.read().strip().split("\n")
        self.assertEqual(lines[0], "path,onset_seq,run_len,t_s,t_mono_ns,t_real_ns")
        self.assertEqual(len(lines), 1 + len(self.bursts))
        first = lines[1].split(",")
        self.assertEqual(int(first[1]), self.bursts[0][0])
        self.assertEqual(int(first[2]), self.bursts[0][1])

    def test_in_window_crc_fail_counts_as_a_loss(self):
        """A crc_ok==0 record inside the live window occupies its slot but does
        NOT place it: the reconstruction reads it as a lost slot, which is right
        (the frame did not arrive intact) and is why the fixture parks its
        crc-bad records pre-settle. Planting one in-window must add exactly one
        single-slot run at that seq."""
        b2 = os.path.join(self.tmp, "frames2.bin")
        synth(b2, bursts=self.bursts, crc_bad_slots=(26_500,))
        r = accept_analyze.analyze(b2, burst_times=True)
        got = [(b["onset_seq"], b["run_len"]) for b in r["bursts"]]
        self.assertIn((26_500, 1), got)
        self.assertEqual(len(got), len(self.bursts) + 1)

    def test_cli_without_the_flag_prints_no_burst_line(self):
        p = subprocess.run(
            [sys.executable, os.path.join(TWO_JUP, "accept_analyze.py"), self.bin],
            capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertNotIn("burst times", p.stdout)
        self.assertIn("PER=", p.stdout)


if __name__ == "__main__":
    unittest.main()
