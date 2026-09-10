#!/usr/bin/env python3
"""test_capture_r3_recovery.py -- RXFIX Task 44: capture_r3.sh's mid-window
recovery routine, EXECUTED at the desk against a fake board.

NO BOARD CONTACT.  The two functions under test (`deliv_now` and
`recover_once`) are lifted verbatim out of capture_r3.sh -- between the stable
anchors `deliv_now(){` and `LEFT=$((DUR - 20))` -- and run with `$W` pointing
at a shell script that IMPERSONATES anyssh.sh + one board: it serves a
dma_rx_ok counter that is frozen (the collapse) until a re-arm is written, and
answers `date +%s` from a scripted clock.  The recovery path is otherwise only
reachable on silicon, during a real collapse, which is exactly the code that
must not be first exercised there.

What is pinned:
  * a recovered collapse writes ONE RECOVERY_EVENT ... outcome=recovered line
    whose excl_start_s is (detect - stall - guard) and whose excl_end_s is
    (delivery-back + settle), and returns 0;
  * a collapse that does NOT clear returns 1 and STILL records the interval,
    with outcome=failed -- a leg that could not be recovered must say when it
    was perturbed;
  * the re-arm reaches the RX board ONLY (never the peer) and is a double tap;
  * the record parses back through ops/recovery_windows.py.
"""
import os
import re
import stat
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
TWO_JUP = os.path.dirname(HERE)
sys.path.insert(0, TWO_JUP)

import recovery_windows  # noqa: E402

CAPTURE = os.path.join(TWO_JUP, "capture_r3.sh")
BEGIN = "deliv_now(){"
END = "LEFT=$((DUR - 20))"
# The WHOLE Task 44 block, including the stall loop that decides whether a leg
# lives or dies AND the verdict that follows it: from the STALL_MAX default down
# to the post-window register snap.
LOOP_BEGIN = "STALL_MAX=${STALL_MAX:-12}"
LOOP_END = 'snap $RX_IP > "$OUT/regs_post.txt"'


def extract_loop():
    src = open(CAPTURE).read()
    i = src.index(LOOP_BEGIN)
    j = src.index(LOOP_END, i)
    return src[i:j]

# The fake board. $1 is the IP, $2 the remote script -- anyssh.sh's own calling
# convention. A re-arm is any remote script containing the 0x000 soft reset;
# REARMS counts them, and delivery only advances once one has landed.
FAKE_BOARD = r"""#!/bin/bash
ip=$1; shift
cmd="$*"
D=$FAKE_STATE
case "$cmd" in
  *"0x000 0x1"*)
      echo "$ip" >> "$D/rearm_ips"
      n=$(cat "$D/rearms" 2>/dev/null || echo 0); echo $((n+1)) > "$D/rearms"
      exit 0 ;;
esac
ok=$(cat "$D/ok"); r=$(cat "$D/rearms" 2>/dev/null || echo 0)
if [ "$r" -ge 1 ] && [ "$FAKE_RECOVERS" = 1 ]; then
  ok=$((ok + 1245*4)); echo "$ok" > "$D/ok"     # delivery back, ~1245 f/s
fi
case "$cmd" in
  *'T=$(date'*)                                  # deliv_now's compound read
      t=$(cat "$D/clock"); echo $((t+2)) > "$D/clock"
      echo "T=$t OK=$ok"; exit 0 ;;
  *"dma_rx_ok"*)                                 # the stall loop's bare read
      echo "$ok"; exit 0 ;;
  *"date +%s"*)
      t=$(cat "$D/clock"); echo $((t+2)) > "$D/clock"; echo "$t"; exit 0 ;;
esac
exit 0
"""


def extract_functions():
    src = open(CAPTURE).read()
    i = src.index(BEGIN)
    j = src.index(END, i)
    return src[i:j]


class TestRecoverOnce(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="t44cap_")
        self.state = os.path.join(self.tmp, "state")
        os.makedirs(self.state)
        with open(os.path.join(self.state, "clock"), "w") as f:
            f.write("1788567000\n")
        with open(os.path.join(self.state, "ok"), "w") as f:
            f.write("1000000\n")
        self.fake = os.path.join(self.tmp, "fakeboard")
        with open(self.fake, "w") as f:
            f.write(FAKE_BOARD)
        os.chmod(self.fake, os.stat(self.fake).st_mode | stat.S_IEXEC)
        self.out = os.path.join(self.tmp, "cap")
        os.makedirs(self.out)

    def _run(self, recovers=True, wait=12):
        script = os.path.join(self.tmp, "drive.sh")
        with open(script, "w") as f:
            f.write("#!/bin/bash\nset -u\n")
            f.write(f'W={self.fake}\nRX_IP=10.0.0.146\nOUT={self.out}\n')
            f.write('RECFILE="$OUT/recovery.txt"\n')
            f.write(f"RECOVER_MAX=1 RECOVER_WAIT={wait} RECOVER_SETTLE=15 "
                    "RECOVER_GUARD_PRE=2 RECOVER_CONFIRM=2\n")
            f.write("RECOVER_EXCL_S=0\n")
            # rearm_byte, verbatim in shape: one bounded ssh carrying 0x000
            f.write('rearm_byte(){ $W $1 \'DRA=x; echo "0x000 0x1">$DRA\'; }\n')
            f.write(extract_functions())
            f.write('\nif recover_once 16 1; then echo RC=0; else echo RC=1; fi\n')
            f.write('echo "EXCL_S=$RECOVER_EXCL_S"\n')
        os.chmod(script, os.stat(script).st_mode | stat.S_IEXEC)
        env = dict(os.environ, FAKE_STATE=self.state,
                   FAKE_RECOVERS="1" if recovers else "0")
        return subprocess.run(["bash", script], capture_output=True, text=True,
                              env=env, timeout=300)

    def test_recovered_collapse_is_recorded_and_returns_zero(self):
        p = self._run(recovers=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("RC=0", p.stdout)
        self.assertIn("MID_RECOVER: RECOVERED", p.stdout)
        rec = recovery_windows.load_recovery(os.path.join(self.out, "frames.bin"))
        self.assertEqual(len(rec["events"]), 1, p.stdout)
        e = rec["events"][0]
        self.assertEqual(e["outcome"], "recovered")
        # excl_start = detect - stall(16) - guard(2)
        self.assertEqual(e["excl_start_s"], float(e["detect_board_s"]) - 16 - 2)
        # excl_end = the confirming poll's board time + settle(15)
        self.assertEqual(e["excl_end_s"], float(e["back_board_s"]) + 15)
        self.assertGreater(e["excl_end_s"], e["excl_start_s"])
        self.assertEqual(rec["excluded_s"], e["excl_end_s"] - e["excl_start_s"])

    def test_failed_recovery_returns_one_and_still_records_the_interval(self):
        p = self._run(recovers=False, wait=12)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("RC=1", p.stdout)
        self.assertIn("did NOT return within", p.stdout)
        rec = recovery_windows.load_recovery(os.path.join(self.out, "frames.bin"))
        self.assertEqual(len(rec["events"]), 1)
        self.assertEqual(rec["events"][0]["outcome"], "failed")
        self.assertEqual(rec["events"][0]["back_board_s"], "NA")
        self.assertGreater(rec["excluded_s"], 0)

    def test_the_rearm_is_rx_only_and_a_double_tap(self):
        self._run(recovers=True)
        with open(os.path.join(self.state, "rearm_ips")) as f:
            ips = [l.strip() for l in f if l.strip()]
        self.assertEqual(ips, ["10.0.0.146", "10.0.0.146"],
                         "the mid-window re-arm must be RX-only and a double tap; "
                         "re-arming the peer stalls its transmit feed (the 7 ms dose) "
                         "and breaks host_seq continuity")

    def test_record_carries_the_schema_and_the_reader_contract(self):
        self._run(recovers=True)
        text = open(os.path.join(self.out, "recovery.txt")).read()
        self.assertIn("RECOVERY_SCHEMA 1", text)
        self.assertIn("t_real_ns", text)          # names the clock it is on
        self.assertIn("recovery_windows.py", text)
        self.assertEqual(len(re.findall(r"^RECOVERY_EVENT", text, re.M)), 1)


class TestStallLoopBranch(unittest.TestCase):
    """The branch that decides whether a leg lives or dies, EXECUTED.

    capture_r3.sh's step-7 stall loop is lifted whole (STALL_MAX default through
    the loop's closing report) and driven against the same fake board, with the
    poll interval and thresholds shrunk so a scenario runs in ~30 s. Three
    scenarios: the knob OFF (today's behaviour must be reproduced exactly), the
    knob on and the receiver recovers, and the knob on and it does not.
    """

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="t44loop_")
        self.state = os.path.join(self.tmp, "state")
        os.makedirs(self.state)
        with open(os.path.join(self.state, "clock"), "w") as f:
            f.write("1788567000\n")
        with open(os.path.join(self.state, "ok"), "w") as f:
            f.write("1000000\n")
        self.fake = os.path.join(self.tmp, "fakeboard")
        with open(self.fake, "w") as f:
            f.write(FAKE_BOARD)
        os.chmod(self.fake, os.stat(self.fake).st_mode | stat.S_IEXEC)
        self.out = os.path.join(self.tmp, "cap")
        os.makedirs(self.out)

    def _run(self, mid_recover, recovers):
        script = os.path.join(self.tmp, "loop.sh")
        with open(script, "w") as f:
            f.write("#!/bin/bash\nset -u\n")
            f.write(f'W={self.fake}\nRX_IP=10.0.0.146\nOUT={self.out}\nDUR=26\n')
            f.write(f"STALL_MAX=4 MID_RECOVER={mid_recover} RECOVER_WAIT=14 "
                    "RECOVER_CONFIRM=1 RECOVER_SETTLE=15 RECOVER_GUARD_PRE=2\n")
            # the verdict string step 5 leaves behind on a healthy pre-window gate
            f.write('WEDGE_NOTE="healthy crc=99% rate=1200f/s"\n')
            f.write('rearm_byte(){ $W $1 \'DRA=x; echo "0x000 0x1">$DRA\'; }\n')
            f.write(extract_loop())
            f.write('\necho "MID_WEDGE=$MID_WEDGE RECOVER_N=$RECOVER_N '
                    'RECOVER_FAILED=$RECOVER_FAILED LEFT=$LEFT"\n')
            f.write('echo "VERDICT<$WEDGE_NOTE>"\n')
        os.chmod(script, os.stat(script).st_mode | stat.S_IEXEC)
        env = dict(os.environ, FAKE_STATE=self.state,
                   FAKE_RECOVERS="1" if recovers else "0")
        p = subprocess.run(["bash", script], capture_output=True, text=True,
                           env=env, timeout=300)
        self.assertEqual(p.returncode, 0, p.stderr)
        m = re.search(r"MID_WEDGE=(\d+) RECOVER_N=(\d+) RECOVER_FAILED=(\d+) LEFT=(-?\d+)",
                      p.stdout)
        self.assertIsNotNone(m, p.stdout)
        v = re.search(r"VERDICT<(.*)>", p.stdout)
        self.assertIsNotNone(v, p.stdout)
        d = dict(zip(("wedge", "n", "failed", "left"), (int(x) for x in m.groups())))
        d["verdict"] = v.group(1)
        return p, d

    def test_knob_off_reproduces_todays_abort(self):
        p, r = self._run(mid_recover=0, recovers=True)
        self.assertEqual((r["wedge"], r["n"], r["failed"]), (1, 0, 0))
        self.assertNotIn("MID_RECOVER:", p.stdout)
        self.assertIn("CAPTURE_ABORTED_WEDGED", p.stdout)
        self.assertTrue(r["verdict"].startswith("MID_CAPTURE_WEDGE"), r["verdict"])
        self.assertFalse(os.path.exists(os.path.join(self.out, "recovery.txt")),
                         "the default path must not write a recovery record")

    def test_knob_on_and_it_recovers_keeps_the_leg(self):
        p, r = self._run(mid_recover=1, recovers=True)
        self.assertEqual((r["wedge"], r["n"], r["failed"]), (0, 1, 0), p.stdout)
        self.assertIn("MID_RECOVER: RECOVERED", p.stdout)
        self.assertIn("traffic window extended", p.stdout)
        # the leg is USABLE but must announce itself as perturbed, and the marker
        # must not contain "WEDGE" or legrun_go.sh's gate would fail a good leg
        self.assertIn("RECOVERED_MIDWINDOW", r["verdict"])
        self.assertNotIn("WEDGE", r["verdict"])
        self.assertNotIn("CAPTURE_ABORTED", p.stdout)
        self.assertGreater(r["left"], 6, "RECOVER_EXTEND must lengthen the window")
        rec = recovery_windows.load_recovery(os.path.join(self.out, "frames.bin"))
        self.assertEqual(len(rec["events"]), 1)
        self.assertEqual(rec["events"][0]["outcome"], "recovered")

    def test_knob_on_and_it_does_not_recover_fails_with_its_own_marker(self):
        p, r = self._run(mid_recover=1, recovers=False)
        self.assertEqual((r["wedge"], r["n"], r["failed"]), (1, 1, 1), p.stdout)
        self.assertIn("CAPTURE_ABORTED_RECOVERY_FAILED", p.stdout)
        self.assertTrue(r["verdict"].startswith("MID_CAPTURE_RECOVERY_FAILED"), r["verdict"])
        self.assertIn("NOT usable data", r["verdict"])   # legrun_go.sh's gate keys on this
        self.assertNotIn("RECOVERED_MIDWINDOW", r["verdict"])
        rec = recovery_windows.load_recovery(os.path.join(self.out, "frames.bin"))
        self.assertEqual(rec["events"][0]["outcome"], "failed")

    def test_only_one_attempt_is_made_at_recover_max_1(self):
        p, r = self._run(mid_recover=1, recovers=False)
        self.assertEqual(p.stdout.count("MID_RECOVER: attempt"), 1, p.stdout)


if __name__ == "__main__":
    unittest.main()
