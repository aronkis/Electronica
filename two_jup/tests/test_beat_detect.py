import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
from beat_detect import detect_frames, detect_seconds

def test_clean_run_has_no_burst():
    rows = [(i, 0, 0) for i in range(1, 5000)]
    assert detect_frames(rows) == []

def test_burst_of_250_frames_is_found_with_bounds():
    rows = [(i, 50 if 1000 <= i < 1250 else 0, 0) for i in range(1, 3000)]
    b = detect_frames(rows)
    assert len(b) == 1 and b[0]['start'] == 1000 and b[0]['end'] == 1249 and b[0]['frames'] == 250

def test_short_blip_is_ignored():
    rows = [(i, 50 if 1000 <= i < 1100 else 0, 0) for i in range(1, 3000)]
    assert detect_frames(rows) == []

def test_rstcs_change_is_reported_not_hidden():
    rows = [(i, 50 if 1000 <= i < 1300 else 0, 1 if i >= 1100 else 0) for i in range(1, 3000)]
    b = detect_frames(rows)
    assert len(b) == 1 and b[0]['rstcs_delta'] == 1

def test_seconds_mode_uses_cumulative_deltas():
    rows = []
    p = e = 0
    for t in range(0, 300):
        p += 1250; e += 20000 if 150 <= t < 155 else 51
        rows.append((t, p, e))
    b = detect_seconds(rows)
    assert len(b) == 1 and b[0]['start'] == 150 and b[0]['end'] == 154
