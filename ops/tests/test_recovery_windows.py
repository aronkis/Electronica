#!/usr/bin/env python3
"""test_recovery_windows.py -- RXFIX Task 44: a harness-recovered mid-window
collapse must be EXCLUDED from scoring, not counted as loss.

The repo's rule (singles_cadence.py): "a scorer that has never caught a planted
fault is not trusted with a negative result." So every test here PLANTS a
collapse of known length at a known instant in a synthesized frames.bin, writes
the recovery.txt capture_r3.sh would have written for it, and asserts:

  * the perturbed interval leaves BOTH the numerator and the denominator -- the
    recovered leg's PER equals the same leg's PER with no collapse at all, and
    it is NOT the (much larger) number you get by counting the gap as loss;
  * the gap never appears as a loss run (no ">100" run, no 2-frame bin moved);
  * QPSK_RECOVERY_IGNORE=1 reproduces the un-excluded number exactly -- that is
    the A/B the validation leg pre-registers, and it is only meaningful if the
    two answers really do differ;
  * with NO recovery.txt every returned number is identical to the pre-Task-44
    code path (the segmentation collapses to one segment).

Board contact: none. Everything here is synthetic frames.bin data on disk.
"""
import os
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
import recovery_windows  # noqa: E402
from frame_taxonomy import DTYPE, read_frames  # noqa: E402
from test_accept_burst_times import FRAME_NS, T_MONO0, T_REAL0, synth  # noqa: E402

# The planted leg: 200 000 slots ~ 160 s at 803 us, comfortably past the 15 s
# settle, with an ordinary singles/doubles loss comb so the PER is non-trivial.
N_SLOTS = 200_000
# UNIFORM by construction: one single every 500 slots across the whole leg, so
# the loss density inside the excluded window is the same as outside it and the
# recovered leg's PER must land on the clean leg's.
COMB_BURSTS = [(s, 1) for s in range(20_000, N_SLOTS, 500)]
# The collapse: 25 000 consecutive slots (~20 s) starting at slot 100 000
# (~80 s in) -- the shape of a real mid-window collapse, which deletes every
# frame until the re-arm clears it.
COLLAPSE_AT = 100_000
COLLAPSE_LEN = 25_000


def _t_real_s(slot):
    return (T_REAL0 + slot * FRAME_NS) / 1e9


def write_recovery(dirpath, excl_start_s, excl_end_s, outcome="recovered", idx=1,
                   extra=""):
    p = os.path.join(dirpath, recovery_windows.RECOVERY_BASENAME)
    with open(p, "w") as f:
        f.write("# capture_r3.sh mid-window recovery record (RXFIX Task 44).\n")
        f.write("RECOVERY_SCHEMA 1\n")
        f.write(f"RECOVERY_EVENT idx={idx} outcome={outcome} rx=10.0.0.146 "
                f"stall_s=16 detect_board_s={int(excl_start_s)+18} "
                f"rearm_board_s={int(excl_start_s)+18} back_board_s={int(excl_end_s)-15} "
                f"wait_s=9 settle_s=15 guard_pre_s=2 "
                f"excl_start_s={excl_start_s:.0f} excl_end_s={excl_end_s:.0f}{extra}\n")
    return p


class TestRecoveryRecordReader(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="t44rec_")
        self.bin = os.path.join(self.tmp, "frames.bin")
        open(self.bin, "wb").close()

    def test_absent_record_is_the_ordinary_leg(self):
        r = recovery_windows.load_recovery(self.bin)
        self.assertFalse(r["present"])
        self.assertEqual(r["events"], [])
        self.assertEqual(r["excluded_s"], 0.0)
        self.assertEqual(recovery_windows.describe(r), "")

    def test_parses_and_sorts_events(self):
        p = os.path.join(self.tmp, "recovery.txt")
        with open(p, "w") as f:
            f.write("RECOVERY_SCHEMA 1\n")
            f.write("RECOVERY_EVENT idx=2 outcome=recovered excl_start_s=300 excl_end_s=330\n")
            f.write("RECOVERY_EVENT idx=1 outcome=recovered excl_start_s=100 excl_end_s=140\n")
        r = recovery_windows.load_recovery(self.bin)
        self.assertEqual([e["idx"] for e in r["events"]], ["1", "2"])
        self.assertEqual(r["excluded_s"], 70.0)
        self.assertIn("70.0 s EXCLUDED", recovery_windows.describe(r))

    def test_malformed_lines_warn_and_are_never_silently_dropped(self):
        p = os.path.join(self.tmp, "recovery.txt")
        with open(p, "w") as f:
            f.write("RECOVERY_SCHEMA 1\n")
            f.write("RECOVERY_EVENT idx=1 outcome=recovered excl_start_s=oops excl_end_s=140\n")
            f.write("RECOVERY_EVENT idx=2 excl_start_s=300 excl_end_s=200\n")
            f.write("RECOVERY_EVENT idx=3 outcome=recovered excl_start_s=500 excl_end_s=560\n")
        r = recovery_windows.load_recovery(self.bin)
        self.assertEqual(len(r["events"]), 1)
        self.assertEqual(len(r["warnings"]), 2)

    def test_unknown_schema_is_flagged_not_ignored(self):
        p = os.path.join(self.tmp, "recovery.txt")
        with open(p, "w") as f:
            f.write("RECOVERY_SCHEMA 99\n")
            f.write("RECOVERY_EVENT idx=1 outcome=recovered excl_start_s=1 excl_end_s=2\n")
        r = recovery_windows.load_recovery(self.bin)
        self.assertEqual(len(r["events"]), 1)
        self.assertTrue(any("newer than this reader" in w for w in r["warnings"]))

    def test_ignore_env_disables_the_whole_mechanism(self):
        write_recovery(self.tmp, 100.0, 140.0)
        os.environ["QPSK_RECOVERY_IGNORE"] = "1"
        try:
            r = recovery_windows.load_recovery(self.bin)
        finally:
            del os.environ["QPSK_RECOVERY_IGNORE"]
        self.assertEqual(r["events"], [])
        self.assertTrue(r.get("ignored"))

    def test_segments_from_mask(self):
        m = np.array([1, 1, 0, 0, 1, 1, 1, 0, 1], dtype=bool)
        self.assertEqual(recovery_windows.segments_from_mask(m),
                         [(0, 2), (4, 7), (8, 9)])
        self.assertEqual(recovery_windows.segments_from_mask(np.ones(5, bool)), [(0, 5)])
        self.assertEqual(recovery_windows.segments_from_mask(np.zeros(5, bool)), [])


class TestExclusionScoring(unittest.TestCase):
    """One planted leg, scored three ways."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="t44exc_")
        # (a) the leg WITHOUT the collapse -- the answer a clean leg gives
        cls.clean_dir = os.path.join(cls.tmp, "clean")
        os.makedirs(cls.clean_dir)
        cls.clean_bin = os.path.join(cls.clean_dir, "frames.bin")
        synth(cls.clean_bin, n_slots=N_SLOTS, bursts=COMB_BURSTS)
        # (b) the SAME leg with a 25 000-slot collapse planted in the middle
        cls.coll_dir = os.path.join(cls.tmp, "recovered")
        os.makedirs(cls.coll_dir)
        cls.coll_bin = os.path.join(cls.coll_dir, "frames.bin")
        # the collapse SUBSUMES the singles it covers (they are the same slots,
        # deleted once) -- exactly what a real collapse does to the comb.
        bursts = sorted(COMB_BURSTS + [(COLLAPSE_AT, COLLAPSE_LEN)])
        synth(cls.coll_bin, n_slots=N_SLOTS, bursts=bursts)
        # the record capture_r3.sh would have written: the collapse bracketed by
        # the 2 s pre-guard and the 15 s post-recovery settle.
        write_recovery(cls.coll_dir,
                       _t_real_s(COLLAPSE_AT) - 2.0,
                       _t_real_s(COLLAPSE_AT + COLLAPSE_LEN) + 15.0)

    def test_the_collapse_leaves_numerator_and_denominator(self):
        clean = accept_analyze.analyze(self.clean_bin)
        rec = accept_analyze.analyze(self.coll_bin)
        self.assertTrue(clean["usable"] and rec["usable"])
        self.assertEqual(rec["recovery_events"], 1)
        self.assertEqual(rec["n_segments"], 2)
        per_clean = 100.0 * clean["miss"] / clean["span"]
        per_rec = 100.0 * rec["miss"] / rec["span"]
        # the excluded leg loses the ~20 s of slots it could not measure, so its
        # denominator is smaller -- but its RATE must match the clean leg's.
        self.assertLess(rec["span"], clean["span"])
        self.assertAlmostEqual(per_rec, per_clean, places=2,
                               msg=f"PER moved: clean {per_clean:.4f}% vs recovered {per_rec:.4f}%")
        # and the collapse is not a loss run anywhere
        self.assertEqual(rec["bins"][">100"], 0)
        self.assertEqual(rec["bins"]["21-100"], 0)

    def test_ignoring_the_record_counts_the_gap_as_loss(self):
        """The A/B the validation leg pre-registers. If this test's two numbers
        were equal, the exclusion would not be wired into the tool at all."""
        os.environ["QPSK_RECOVERY_IGNORE"] = "1"
        try:
            naive = accept_analyze.analyze(self.coll_bin)
        finally:
            del os.environ["QPSK_RECOVERY_IGNORE"]
        rec = accept_analyze.analyze(self.coll_bin)
        self.assertEqual(naive["recovery_events"], 0)
        self.assertEqual(naive["bins"][">100"], 1)      # the collapse, as one run
        self.assertEqual(rec["bins"][">100"], 0)
        # everything inside the perturbed interval leaves the numerator: the
        # 25 000-slot collapse plus the few ordinary singles in the guard/settle.
        self.assertGreaterEqual(naive["miss"] - rec["miss"], COLLAPSE_LEN)
        self.assertGreater(100.0 * naive["miss"] / naive["span"],
                           3 * 100.0 * rec["miss"] / rec["span"])

    def test_no_record_means_no_change_at_all(self):
        """Byte-for-byte the pre-Task-44 arithmetic when nothing is excluded."""
        r = accept_analyze.analyze(self.clean_bin)
        self.assertEqual(r["recovery_events"], 0)
        self.assertEqual(r["n_segments"], 1)
        self.assertEqual(r["excluded_s"], 0.0)
        fr = read_frames(self.clean_bin)
        clean = fr["crc_ok"] != 0
        ci = np.flatnonzero(clean)
        ts = (fr["t_mono_ns"].astype(np.int64) - fr["t_mono_ns"][0]) / 1e9
        cw = fr["host_seq"][ci][(ts[ci] >= 15.0)].astype(np.int64)
        d = np.diff(cw)
        self.assertEqual(r["span"], int(cw[-1] - cw[0]))
        self.assertEqual(r["miss"], int((d - 1)[(d - 1) > 0].sum()))

    def test_a_truncated_recovered_tail_is_flagged_not_silent(self):
        """The dangerous failure: the live-window rule puts live_end at or
        before the collapse (the post-recovery buckets never reach 25 % of the
        pre-collapse peak), so the recovered tail is dropped BEFORE the
        exclusion runs and a plausible PER is reported on the pre-collapse
        segment alone. Simulated here by pointing the record at an interval
        past the end of the leg -- the same observable: events > 0, segments
        < 2. The CLI must say so."""
        d = os.path.join(self.tmp, "late")
        os.makedirs(d, exist_ok=True)
        b = os.path.join(d, "frames.bin")
        synth(b, n_slots=N_SLOTS, bursts=COMB_BURSTS)
        write_recovery(d, _t_real_s(N_SLOTS) + 100.0, _t_real_s(N_SLOTS) + 160.0)
        r = accept_analyze.analyze(b)
        self.assertEqual(r["recovery_events"], 1)
        self.assertEqual(r["n_segments"], 1)
        p = subprocess.run([sys.executable,
                            os.path.join(TWO_JUP, "accept_analyze.py"), b],
                           capture_output=True, text=True)
        self.assertIn("*** CHECK:", p.stdout)
        self.assertIn("recovered tail was DROPPED", p.stdout)

    def test_cli_says_the_leg_is_perturbed(self):
        p = subprocess.run([sys.executable,
                            os.path.join(TWO_JUP, "accept_analyze.py"), self.coll_bin],
                           capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("PERTURBED LEG", p.stdout)
        self.assertIn("EXCLUDED from numerator AND denominator", p.stdout)
        self.assertIn("PERTURBED legs in this pool: 1", p.stdout)
        self.assertIn("RECOVERED LEG:", p.stderr)

    def test_loss_slot_trains_excludes_and_reports_the_denominator(self):
        from common import loss_slot_trains  # noqa: E402
        fr = read_frames(self.coll_bin)
        naive = loss_slot_trains(fr)                       # no path -> no exclusion
        lt = loss_slot_trains(fr, path=self.coll_bin)
        self.assertEqual(naive["n_slots_scored"], naive["n_slots"])
        self.assertLess(lt["n_slots_scored"], lt["n_slots"])
        self.assertEqual(lt["n_segments"], 2)
        self.assertGreaterEqual(int(naive["all_loss"].sum()) - int(lt["all_loss"].sum()),
                                COLLAPSE_LEN)
        self.assertEqual(lt["run_bins"][">100"], 0)
        self.assertEqual(naive["run_bins"][">100"], 1)
        # the excluded slots are zeroed in the trains but still ON the axis, so
        # the slot phase every comb tool measures is unshifted
        self.assertEqual(lt["n_slots"], naive["n_slots"])
        hole = np.flatnonzero(lt["scored"] == 0)
        self.assertTrue(hole.size > 0)
        self.assertEqual(int(lt["all_loss"][hole].sum()), 0)
        self.assertEqual(int(lt["singles"][hole].sum()), 0)

    def test_comb_period_ms_divides_by_the_scored_slots(self):
        import comb_period_ms  # noqa: E402
        r = comb_period_ms.analyze(self.coll_bin, n_shuffle=2)
        self.assertTrue(r["usable"])
        self.assertEqual(r["recovery_events"], 1)
        self.assertLess(r["n_slots_scored"], r["n_slots"])
        self.assertAlmostEqual(r["per_pct"], 100.0 * r["n_lost"] / r["n_slots_scored"],
                               places=9)
        # the collapse must not have become the dominant "loss" population
        self.assertLess(r["per_pct"], 5.0)


class TestCaptureR3Defaults(unittest.TestCase):
    """capture_r3.sh runs on every future leg: the new behaviour must be off."""

    def setUp(self):
        with open(os.path.join(TWO_JUP, "capture_r3.sh")) as f:
            self.src = f.read()

    def test_knob_defaults_to_off_and_is_documented(self):
        self.assertIn("MID_RECOVER=${MID_RECOVER:-0}", self.src)
        self.assertIn("MID_RECOVER  -- KNOB NAME AND DEFAULT: MID_RECOVER=0 (OFF)", self.src)

    def test_recovery_is_only_reached_with_the_knob_on(self):
        self.assertIn('if [ "$MID_RECOVER" != 1 ] || [ "$RECOVER_N" -ge "$RECOVER_MAX" ]; then',
                      self.src)
        self.assertIn("CAPTURE_ABORTED_WEDGED", self.src)          # today's marker kept

    def test_a_failed_recovery_has_its_own_marker_and_still_exits_3(self):
        self.assertIn("CAPTURE_ABORTED_RECOVERY_FAILED", self.src)
        self.assertIn("MID_CAPTURE_RECOVERY_FAILED", self.src)
        # ...and carries "NOT usable data", which is what legrun_go.sh's
        # existing gate keys on, so no caller has to learn the new string
        self.assertIn('MID_CAPTURE_RECOVERY_FAILED after ${WAITED}s wall '
                      '(delivery flatlined ${STALL}s; $RECOVER_N of $RECOVER_MAX '
                      're-arms, ${RECOVER_WAIT}s wait each) -- NOT usable data',
                      self.src)

    def test_the_rearm_is_rx_only_and_a_double_tap(self):
        self.assertIn('rearm_byte "$RX_IP"; sleep 3; rearm_byte "$RX_IP"', self.src)

    def test_a_stale_recovery_record_cannot_govern_a_new_leg(self):
        """recovery.txt is what the scorers silently key on, and a re-run into
        an existing -o dir overwrites frames.bin -- so a leftover record must be
        removed before the leg starts, or the NEW leg is scored as perturbed
        over an interval belonging to the old one."""
        self.assertIn('rm -f "$OUT/recovery.txt"', self.src)
        i = self.src.index('rm -f "$OUT/recovery.txt"')
        j = self.src.index('# 1. deploy qpsk_tun source')
        self.assertLess(i, j, "the stale-record removal must happen before the leg runs")

    def test_recovered_marker_cannot_trip_a_wedge_gate(self):
        self.assertNotIn("WEDGE", "RECOVERED_MIDWINDOW")
        self.assertIn("RECOVERED_MIDWINDOW", self.src)


if __name__ == "__main__":
    unittest.main()
