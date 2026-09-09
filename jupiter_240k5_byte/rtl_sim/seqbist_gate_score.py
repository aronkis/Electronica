#!/usr/bin/env python3
"""seqbist_gate_score.py -- score the SEQ-BIST T0c full-loop sim gates G1-G4.

Host-only.  Reads the run manifest (seqbist_gate_runs.txt), each run's
`<pfx>_summary.txt` (key=value, written by sim_byte_seqbist.cpp) and
`<pfx>_csv.txt` (a mux-read counter row every 100 frames), and writes
`beat_runs/seqbist_gate_summary.txt` lines

    SEQBIST_GATE <id> PASS|FAIL <evidence>

Two refusals that are the point of the script, both inherited from the TXFIX
gate lesson (partial, still-growing files were once scored as final):

 1. **No trailer, no score.**  A run is only final when its wrapper log
    (`beat_runs/seqbist_gate_<id>.log`) carries `SEQBIST_GATE_RUN_EXIT=<code>`
    printed AFTER the binary returned.  Missing trailer -> FAIL(no-exit-trailer),
    never a PASS.  The driver also prints the trailer itself; every occurrence
    must be 0 and the LAST one is authoritative.
 2. **No unit mismatch.**  The interval counters were redefined by the
    2026-09-03 operator ruling from received-frame to EMITTED-frame (seq delta)
    units.  The harness stamps which units the compiled RTL implements
    (`int_units=` in the summary); if it is not what the scorer expects, the run
    is refused rather than scored against the wrong constant.  With
    `skip_every=N` the expected interval is N+1 in seq-delta units (the skipped
    slot is inside the delta) and N in received units; with `corrupt_every=M` it
    is M and M-1 respectively.  Accepting "either" would make the check
    unfalsifiable, so the scorer requires exactly one.
"""
import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
BR = os.path.join(HERE, 'beat_runs')
DEFAULT_MANIFEST = os.path.join(HERE, 'seqbist_gate_runs.txt')
EXPECT_UNITS = 'seqdelta'

MANIFEST_COLS = ['gid', 'nframes', 'skip_every', 'corrupt_every', 'fill', 'gap',
                 'pfx', 'force', 'max_mclks', 'expect_filler']


# ---------------------------------------------------------------- readers ----
def read_manifest(path):
    runs = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            parts = line.split('|')
            if len(parts) < 9:
                continue
            cfg = dict(zip(MANIFEST_COLS, parts))
            for k in ('nframes', 'skip_every', 'corrupt_every', 'fill', 'gap',
                      'max_mclks', 'expect_filler'):
                cfg[k] = int(cfg.get(k) or 0)
            runs.append(cfg)
    return runs


def read_kv(path):
    d = {}
    if not os.path.exists(path):
        return d
    with open(path) as f:
        for line in f:
            if '=' in line:
                k, v = line.strip().split('=', 1)
                d[k] = v
    return d


def as_int(d, key, default=None):
    try:
        return int(d[key])
    except (KeyError, ValueError):
        return default


def read_csv(path):
    rows = []
    if not os.path.exists(path):
        return rows
    with open(path) as f:
        hdr = None
        for line in f:
            line = line.strip()
            if not line:
                continue
            if line.startswith('#'):
                hdr = [c.strip() for c in line.lstrip('# ').split(',')]
                continue
            if hdr is None:
                continue
            vals = line.split(',')
            if len(vals) != len(hdr):
                continue
            try:
                rows.append({k: int(v) for k, v in zip(hdr, vals)})
            except ValueError:
                continue
    return rows


def run_exit_codes(logpath):
    """Every SEQBIST_GATE_RUN_EXIT value in the wrapper log, in order.

    Empty list = the run is NOT confirmed complete (still in flight, never
    launched, or killed); it must never be scored."""
    if not logpath or not os.path.exists(logpath):
        return []
    with open(logpath) as f:
        txt = f.read()
    return [int(m) for m in re.findall(r'SEQBIST_GATE_RUN_EXIT=(-?\d+)', txt)]


def log_path_for(gid, br=None):
    return os.path.join(br or BR, 'seqbist_gate_%s.log' % gid)


# ----------------------------------------------------------------- gates -----
def _near(a, b, tol):
    return abs(a - b) <= tol


def expected_interval(cfg, units):
    """The seq/received interval a positive control must produce."""
    if cfg['skip_every']:
        n = cfg['skip_every']
        return n + 1 if units == 'seqdelta' else n
    if cfg['corrupt_every']:
        m = cfg['corrupt_every']
        return m if units == 'seqdelta' else m - 1
    return None


def interval_bin(ival):
    if ival < 30:
        return 'int_lt30'
    if ival == 32:
        return 'int_32'
    if ival == 33:
        return 'int_33'
    return 'int_other'


def _common_checks(cfg, s, ev):
    """Checks every gate shares.  Returns a list of failure strings."""
    bad = []
    if as_int(s, 'complete', 0) != 1:
        bad.append('run-incomplete(frames=%s target=%s)'
                   % (s.get('frames'), cfg['nframes']))
    frames = as_int(s, 'frames', 0)
    if frames < cfg['nframes']:
        bad.append('frames<%d' % cfg['nframes'])
    ev['frames'] = frames
    ev['emitted'] = as_int(s, 'emitted_in_window', 0)
    ev['packets_delta'] = as_int(s, 'packets_delta', 0)
    return bad


def _filler_checks(cfg, s, ev):
    """The internal-loopback filler artefact: this netlist emits a packets_out
    increment every 98,664 clocks but consumes one host frame per 197,328 (the
    2x-packets artefact recorded in beat_runs/THROUGHPUT.md), so every other
    delivered RX frame is an all-zero filler frame that the checker correctly
    counts as `garbage`.  It is a property of the sim rail, NOT of the checker,
    so a gate with expect_filler=1 requires the filler to be exactly accounted:
    good-magic frames == emitted frames, and the rest == garbage."""
    bad = []
    frames = as_int(s, 'frames', 0)
    garbage = as_int(s, 'garbage', 0)
    emitted = as_int(s, 'emitted_in_window', 0)
    good_magic = frames - garbage
    ev['garbage'] = garbage
    ev['good_magic'] = good_magic
    if cfg['expect_filler']:
        # every good-magic frame must be a real emitted frame (+-2 for the
        # frames in flight in the TX/RX pipes at the freeze instant)
        if not _near(good_magic, emitted, 3):
            bad.append('good_magic(%d)!=emitted(%d)+-3' % (good_magic, emitted))
        # the filler count is EXACTLY the frames the rail added on top of the
        # emitted ones; without this equality a genuinely corrupted frame could
        # hide inside the filler allowance and still pass the ratio band
        if not _near(garbage, frames - emitted, 3):
            bad.append('garbage(%d)!=filler(frames-emitted=%d)+-3: %d frames '
                       'corrupted beyond the rail filler'
                       % (garbage, frames - emitted,
                          garbage - (frames - emitted)))
        ratio = garbage / frames if frames else 0.0
        ev['filler_ratio'] = round(ratio, 4)
        # a loose sanity band only -- the exact check is the equality above.
        # The band has to cover the gap sweep: at a TGEN gap above the
        # consumption period the generator under-supplies on purpose (to avoid
        # over-run drops) and the filler fraction rises well above 1/2.
        if not (0.20 <= ratio <= 0.80):
            bad.append('filler_ratio=%.3f outside 0.20..0.80' % ratio)
    else:
        if garbage != 0:
            bad.append('garbage=%d (expected 0)' % garbage)
    return bad


def score_g1(cfg, s, rows):
    ev = {}
    bad = _common_checks(cfg, s, ev)
    bad += _filler_checks(cfg, s, ev)
    # with no gap events the interval logic must be silent too, otherwise a
    # checker that spuriously bins intervals would pass the clean gate
    for k in ('lost_slots', 'crc_fail', 'gap_events', 'dup_or_reorder',
              'int_last', 'int_lt30', 'int_32', 'int_33', 'int_other'):
        v = as_int(s, k, -1)
        ev[k] = v
        if v != 0:
            bad.append('%s=%d (expected 0)' % (k, v))
    frames = as_int(s, 'frames', 0)
    pd = as_int(s, 'packets_delta', -1)
    # packets_out is sampled inside the same freeze window; +-1 for the frame in
    # flight between the frame-sync and the byte-plane delivery
    if not _near(frames, pd, 1):
        bad.append('frames(%d)!=packets_delta(%d)+-1' % (frames, pd))
    return (not bad), ev, bad


def score_g2(cfg, s, rows, units):
    ev = {}
    bad = _common_checks(cfg, s, ev)
    bad += _filler_checks(cfg, s, ev)
    n = cfg['skip_every']
    if n <= 0:
        return False, ev, ['G2 manifest has skip_every=0']
    emitted = as_int(s, 'emitted_in_window', 0)
    exp_gaps = emitted // n
    gapev = as_int(s, 'gap_events', -1)
    ev['gap_events'] = gapev
    ev['expected_gaps'] = exp_gaps
    if not _near(gapev, exp_gaps, 1):
        bad.append('gap_events=%d expected floor(%d/%d)=%d+-1'
                   % (gapev, emitted, n, exp_gaps))
    for k, want in (('gap1', gapev), ('gap2', 0), ('gap3plus', 0),
                    ('dup_or_reorder', 0), ('crc_fail', 0)):
        v = as_int(s, k, -1)
        ev[k] = v
        if v != want:
            bad.append('%s=%d (expected %d)' % (k, v, want))
    lost = as_int(s, 'lost_slots', -1)
    ev['lost_slots'] = lost
    if lost != gapev:
        bad.append('lost_slots=%d != gap_events=%d (every skip loses one slot)'
                   % (lost, gapev))
    exp_iv = expected_interval(cfg, units)
    iv = as_int(s, 'int_last', -1)
    ev['int_last'] = iv
    ev['expected_int_last'] = exp_iv
    ev['int_units'] = units
    if iv != exp_iv:
        bad.append('int_last=%d expected %d in %s units' % (iv, exp_iv, units))
    # the whole histogram must sit in the bin the expected interval falls in
    binname = interval_bin(exp_iv)
    ev['int_bin'] = binname
    binned = as_int(s, binname, -1)
    if not _near(binned, max(gapev - 1, 0), 1):
        bad.append('%s=%d expected gap_events-1=%d+-1'
                   % (binname, binned, max(gapev - 1, 0)))
    for other in ('int_lt30', 'int_32', 'int_33', 'int_other'):
        if other == binname:
            continue
        v = as_int(s, other, -1)
        ev[other] = v
        if v != 0:
            bad.append('%s=%d (expected 0)' % (other, v))
    return (not bad), ev, bad


def score_g3(cfg, s, rows, units):
    ev = {}
    bad = _common_checks(cfg, s, ev)
    m = cfg['corrupt_every']
    if m <= 0:
        return False, ev, ['G3 manifest has corrupt_every=0']
    frames = as_int(s, 'frames', 0)
    garbage = as_int(s, 'garbage', -1)
    emitted = as_int(s, 'emitted_in_window', 0)
    ev['garbage'] = garbage
    # deliberate corruptions, plus (on the sim rail) the filler frames
    exp_corrupt = emitted // m
    ev['expected_corrupt'] = exp_corrupt
    filler = (frames - emitted) if cfg['expect_filler'] else 0
    ev['filler'] = filler
    if not _near(garbage - filler, exp_corrupt, 1):
        bad.append('garbage-filler=%d expected floor(%d/%d)=%d+-1'
                   % (garbage - filler, emitted, m, exp_corrupt))
    gapev = as_int(s, 'gap_events', -1)
    ev['gap_events'] = gapev
    # each corrupted frame drops out of seq tracking -> exactly one gap1 after it
    if not _near(gapev, exp_corrupt, 1):
        bad.append('gap_events=%d expected one per corrupted frame (%d)+-1'
                   % (gapev, exp_corrupt))
    gap1 = as_int(s, 'gap1', -1)
    ev['gap1'] = gap1
    if gap1 != gapev:
        bad.append('gap1=%d != gap_events=%d' % (gap1, gapev))
    for k in ('gap2', 'gap3plus', 'dup_or_reorder', 'crc_fail'):
        v = as_int(s, k, -1)
        ev[k] = v
        if v != 0:
            bad.append('%s=%d (expected 0)' % (k, v))
    lost = as_int(s, 'lost_slots', -1)
    ev['lost_slots'] = lost
    if lost != gapev:
        bad.append('lost_slots=%d != gap_events=%d' % (lost, gapev))
    exp_iv = expected_interval(cfg, units)
    iv = as_int(s, 'int_last', -1)
    ev['int_last'] = iv
    ev['expected_int_last'] = exp_iv
    ev['int_units'] = units
    if iv != exp_iv:
        bad.append('int_last=%d expected %d in %s units' % (iv, exp_iv, units))
    return (not bad), ev, bad


def score_g4(cfg, s, rows, recovery_frames=500):
    """Forced ByteWordBuffer over-run (the G4 force).

    Mechanism: the TGEN gap is driven to 0 for a window, so the generator offers
    ~3 frames per 2 air frames; the TX chain accepts what it cannot transmit and
    whole sequence numbers go missing.  (The other force, `starve` -- withholding
    TX data -- was measured on this rail to only DELAY frames: the byte plane
    back-pressures, the generator resumes with the same seq, nothing is lost and
    the checker correctly reports no gap.  It is kept in the harness as the
    negative control, not as G4.)

    Three parts, so the gate cannot pass vacuously:
      (a) the force LANDED -- the generator really did over-supply during the
          window (emitted frames >= 2x the air-frame count of that window).
          Note bwb_min/avail are NOT usable evidence: the ByteWordBuffer reaches
          0 in every run, forced or not (bwb_min_global=0 even in G1).
      (b) the loss was COUNTED -- lost_slots and gap_events both non-zero.
      (c) the checker RECOVERED -- frames keep advancing for at least
          `recovery_frames` after the event with no new gap/dup/lost and no
          garbage beyond the filler allowance."""
    ev = {}
    bad = _common_checks(cfg, s, ev)
    kind = as_int(s, 'force_kind', 0)
    ev['force_kind'] = kind
    if kind != 2:
        return False, ev, ['G4 needs the overrun force (force_kind=2), got %r'
                           % s.get('force', 'none')]
    em_force = as_int(s, 'emitted_in_force', 0)
    try:
        win = float(s.get('frames_per_force_window', '0'))
    except ValueError:
        win = 0.0
    ev['emitted_in_force'] = em_force
    ev['air_frames_in_force'] = round(win, 2)
    if win <= 0 or em_force < 2 * win:
        bad.append('force did not land: %d frames emitted in a window of %.2f '
                   'air frames (needs >= 2x)' % (em_force, win))
    lost = as_int(s, 'lost_slots', 0)
    gapev = as_int(s, 'gap_events', 0)
    crc_fail = as_int(s, 'crc_fail', 0)
    garbage = as_int(s, 'garbage', 0)
    ev.update(lost_slots=lost, gap_events=gapev, crc_fail=crc_fail,
              garbage=garbage)
    if lost < 1 or gapev < 1:
        bad.append('over-run produced no counted loss (lost_slots=%d '
                   'gap_events=%d)' % (lost, gapev))
    if as_int(s, 'dup_or_reorder', 0) != 0:
        bad.append('dup_or_reorder=%d (expected 0)' % as_int(s, 'dup_or_reorder', 0))
    # recovery: split the CSV at the force
    fend = as_int(s, 'force_end_clk', -1)
    post = [r for r in rows if fend >= 0 and r['clk'] > fend]
    ev['post_rows'] = len(post)
    if len(post) < 2:
        bad.append('no post-force CSV rows (recovery window too short)')
    else:
        adv = post[-1]['frames'] - post[0]['frames']
        ev['post_force_frames'] = adv
        if adv < recovery_frames:
            bad.append('post-force frames advanced only %d (< %d): checker did '
                       'not keep counting' % (adv, recovery_frames))
        tail = [r for r in post if post[-1]['frames'] - r['frames'] <= recovery_frames]
        if len(tail) >= 2:
            span = tail[-1]['frames'] - tail[0]['frames']
            dg = tail[-1]['garbage'] - tail[0]['garbage']
            dd = tail[-1]['dup_or_reorder'] - tail[0]['dup_or_reorder']
            dl = tail[-1]['lost_slots'] - tail[0]['lost_slots']
            dge = tail[-1]['gap_events'] - tail[0]['gap_events']
            ev.update(tail_dgarbage=dg, tail_ddup=dd, tail_dlost=dl,
                      tail_dgapev=dge)
            allow = span // 2 + 2 if cfg['expect_filler'] else 0
            if dg > allow:
                bad.append('tail garbage grew by %d (> filler allowance %d): '
                           'checker desynchronised' % (dg, allow))
            if dd or dl or dge:
                bad.append('tail dup=%d lost=%d gap_events=%d after recovery '
                           '(expected 0): checker desynchronised' % (dd, dl, dge))
    return (not bad), ev, bad


SCORERS = {'G1': score_g1, 'G1B': score_g1, 'G1C': score_g1, 'G2': score_g2, 'G3': score_g3, 'G4': score_g4}


def score_run(cfg, br=BR, expect_units=EXPECT_UNITS, recovery_frames=700):
    """-> (gid, 'PASS'|'FAIL', evidence string)"""
    gid = cfg['gid']
    codes = run_exit_codes(log_path_for(gid, br))
    if not codes:
        return gid, 'FAIL', 'no-exit-trailer (run not confirmed complete; refusing to score)'
    if any(c != 0 for c in codes):
        return gid, 'FAIL', 'run-exit=%s' % (','.join(str(c) for c in codes))
    pfx = cfg['pfx']
    if not os.path.isabs(pfx):
        pfx = os.path.join(HERE, pfx)
    s = read_kv(pfx + '_summary.txt')
    if not s:
        return gid, 'FAIL', 'no summary at %s_summary.txt' % cfg['pfx']
    units = s.get('int_units', 'unknown')
    if units != expect_units:
        return gid, 'FAIL', ('int_units=%s but the gate expects %s -- stale build, '
                             'refusing to score' % (units, expect_units))
    rows = read_csv(pfx + '_csv.txt')
    fn = SCORERS.get(gid.upper())
    if fn is None:
        return gid, 'FAIL', 'no scorer for gate %s' % gid
    if gid.upper() in ('G2', 'G3'):
        ok, ev, bad = fn(cfg, s, rows, units)
    elif gid.upper() == 'G4':
        ok, ev, bad = fn(cfg, s, rows, recovery_frames)
    else:
        ok, ev, bad = fn(cfg, s, rows)
    ev['rtl_sha'] = s.get('rtl_sha', '?')
    ev['int_units'] = units
    ev['nframes'] = cfg['nframes']
    evs = ' '.join('%s=%s' % (k, v) for k, v in sorted(ev.items()))
    if ok:
        return gid, 'PASS', evs
    return gid, 'FAIL', evs + ' || ' + '; '.join(bad)


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--manifest', default=DEFAULT_MANIFEST)
    ap.add_argument('--beat-runs', default=BR)
    ap.add_argument('--expect-units', default=EXPECT_UNITS,
                    choices=['seqdelta', 'received'])
    ap.add_argument('--recovery-frames', type=int, default=500)
    ap.add_argument('--out', default=None)
    ap.add_argument('--gid', action='append', default=None)
    args = ap.parse_args(argv)

    runs = read_manifest(args.manifest)
    if args.gid:
        runs = [r for r in runs if r['gid'] in args.gid]
    lines = []
    npass = 0
    for cfg in runs:
        gid, verdict, ev = score_run(cfg, br=args.beat_runs,
                                     expect_units=args.expect_units,
                                     recovery_frames=args.recovery_frames)
        lines.append('SEQBIST_GATE %s %s %s' % (gid, verdict, ev))
        npass += (verdict == 'PASS')
    out = args.out or os.path.join(args.beat_runs, 'seqbist_gate_summary.txt')
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, 'w') as f:
        f.write('\n'.join(lines) + '\n')
    for l in lines:
        print(l)
    print('SEQBIST_GATE_SCORE_DONE pass=%d of %d -> %s' % (npass, len(runs), out))
    return 0 if (runs and npass == len(runs)) else 1


if __name__ == '__main__':
    sys.exit(main())
