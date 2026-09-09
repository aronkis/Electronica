# PER Ballpark Runbook — 148 (txfixF3) <-> 146 (vendh), both directions, >=10 min

Goal: a defensible ballpark packet error rate over the live RF link between board A
(10.0.0.148, txfixF3 image `f6a8c3ea119c`) and board B (10.0.0.146, unchanged, `vendh
ec414d2df8bc`), forward and reverse, >=600 s each, against the shipped rig defaults, with
dropped/lost frames counted in the denominator. This document is the procedure only —
producing it required no board contact (read-only research; see header of the source
session).

## 0. Which proven procedure this picks, and why

Three PER-measurement lineages exist in `two_jup/`:

- `link_test.sh` / `link_test_f1536.sh` — R0 legacy stack (1.92 MSPS, `lvds_1p92_mhz`
  profile), `ber` subcommand, BIST-mode BER against a fixed reference pattern. Proven, but
  it is the **BIST/loopback profile the board is sitting in right now** ("mode-1"), not a
  live-traffic delivered-PER measurement, and it is a different radio profile than the one
  the August reference numbers below were measured on.
- `arq_per_ab.sh` / `bn2_per_ab.sh` — A/B experiment harnesses (ARQ on/off, Bn x2 timing
  loop) that call `capture_r3.sh` + `accept_analyze.py` per arm. Proven, but built for a
  *comparison*, not a single-configuration ballpark; they are cited here only as the most
  recent evidence that the pipeline they use is alive and correct.
- **`bringup_r2r3.sh r3` + `capture_r3.sh {A|B}` + `accept_analyze.py`** — the R3/f1536
  stack (61.44 MSPS / 15.36 Msym/s, `lvds_61p44_fdd_jupiter`). This is the pipeline that
  produced the standing shipped-default reference numbers (forward 8.73/8.89 %, reverse
  1.391 %, see `~/.claude/projects/.../memory/shipped-defaults-2026-08.md`), is what
  `delivery_sentinel.sh` itself calls (`GATE_DIR=A GATE_TRIES=8 bringup_r2r3.sh r3`), and
  is the most recently exercised chain (2026-09-01 rig-recovery commits: "146 restored
  0->960 f/s by a clean r3 run", "gate (1120) failed"). **Chosen.**

Consequence: bringing the link up for this measurement means `bringup_r2r3.sh r3`
re-arms **both** boards fresh into the r3 radio profile (`lvds_61p44_fdd_jupiter`,
byte-DMA source). This **supersedes** 148's current mode-1 BIST-loopback arm
(`lvds_1p92_mhz`, `arm148_mode1.sh`, from the txfixF3 acceptance chain,
`two_jup/TXFIX_STATE.md` §7) — that is expected and required, not a side effect to avoid.
`TXFIX_STATE.md` §7 says this explicitly: the mode-1 BIST tool gives no real PER number
("no byte-DMA regression on F3 ... no PER number for the beat from this tool — a paced or
over-RF RXONLY measurement (dropped frames in the denominator, >=10 min) is the way to get
one"), which is exactly this runbook's job.

## 1. Preconditions

1. **Sentinel is stopped.** Verify, do not assume:
   `ls -la ~/modem-status/SENTINEL_STOP` (present) and
   `systemctl --user list-units --state=running | grep -i sentinel` (nothing running).
   Do not delete `SENTINEL_STOP` or restart the sentinel unit while this runbook is in
   progress — the sentinel's own bring-up (`GATE_DIR=A`, forward-only gate) will race a
   manual bring-up on the same boards.
2. **Roles for each leg** (fixed by the r3 stack's wiring, `bringup_r2r3.sh`):
   - Board A = 10.0.0.148 (txfixF3), tun 10.66.0.2, Tx LO 1.9 GHz, Rx LO ~2.0 GHz (+20 kHz
     off-null).
   - Board B = 10.0.0.146 (vendh), tun 10.66.0.1, Tx LO 2.0 GHz, Rx LO ~1.9 GHz (+40 kHz
     off-null).
   - **Forward leg** = 146 TX -> 148 RX (`capture_r3.sh A`, board A/148 is the RX capture
     target).
   - **Reverse leg** = 148 TX -> 146 RX (`capture_r3.sh B`, board B/146 is the RX capture
     target).
3. **Shipped rig defaults to measure against** (`bringup_r2r3.sh`, do not change):
   `QPSK_RX_QUEUED=${RXQ:-1}` (queued S2MM RX), `LO_A_RX=${LO_A_RX:-2000020000}` (148 Rx,
   +20 kHz off-null), `LO_B_RX=${LO_B_RX:-1900040000}` (146 Rx, +40 kHz off-null),
   `-M ${RXM:-16}` frame batching, profile `lvds_61p44_fdd_jupiter`, `-r 15360`, nominal
   1245 f/s. Do not pass overrides for these — an override means you are no longer
   measuring the shipped configuration.
4. **Verify both boards are in link mode after bring-up** by reading
   `bringup_r2r3.sh`'s own gate output: `ARM GATE PASS (try N)` with both `148 rx=... f/s`
   and `146 rx=... f/s` >= `GATE_FPS` (90 % of 1245 = 1120 f/s by default), followed by
   `=== r3 BRING-UP COMPLETE ...`. A `WARNING: watchdog NOT running` line means investigate
   before proceeding — the watchdog is what recovers a wedge during normal operation
   (it is deliberately killed again inside `capture_r3.sh`, step 3, for the duration of the
   measurement window only).
5. **Arm-lottery / no-ping-hang discipline**
   (`~/.claude/projects/.../memory/rig-noping-hang-dra-during-arm.md`):
   - `bringup_r2r3.sh` already double-taps the arm and re-arms up to `GATE_TRIES` times —
     this is the proven defense against the false-lock arm lottery. Do not shortcut it.
   - **Every register poll must stay at 1 s or slower.** The 2026-09-01 hang was caused by
     a 0.25 s poll with no arm in flight at all — the fault is *any* `direct_reg_access`
     traffic racing board state, not specifically arming.
   - **Never kill a bring-up or a gated restore mid-arm.** `systemctl --user stop` on a
     bare `systemd-run --user` unit landed a SIGKILL mid-arm and hung a board on
     2026-08-31 (`TimeoutStopSec` default 90 s is shorter than a gated restore). Always
     launch through `two_jup/launch_rig_unit.sh` (`TimeoutStopSec=600`), never bare
     `systemd-run --user`.
   - A **resumed** gated restore (one that wakes up mid-arm after an interruption) is not
     a valid restore — it skips the arm and reads stale register state
     (`RESUME_20260901_1620.md` §7). If a bring-up is ever interrupted, kill it fully and
     start a clean run, don't let it "resume."
   - `launch_rig_unit.sh` forwards **no positional arguments**, only `K=V` env pairs
     (`--setenv`) — `bringup_r2r3.sh` takes `r2|r3` as `$1`, not an env var, so it needs a
     one-line absolute-path wrapper script when launched as a rig unit (see 2a). A bare
     `launch_rig_unit.sh <unit> two_jup/bringup_r2r3.sh r3` fails before touching either
     board because `r3` is silently dropped (documented failure mode,
     `RESUME_20260901_1620.md` §7 item 3) — safe, but wastes a cycle.

## 2. Bring the link up

### 2a. One-line wrapper (required — see precondition 5 last bullet)

```bash
cat > /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup/r3_bringup_go.sh <<'EOF'
#!/bin/bash
D=$(cd "$(dirname "$0")" && pwd)
exec "$D/bringup_r2r3.sh" r3
EOF
chmod +x /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup/r3_bringup_go.sh
```

### 2b. Launch as a rig unit (default GATE_DIR=both — we need BOTH directions live)

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup
bash launch_rig_unit.sh perballpark-bringup-$(date +%H%M%S) "$PWD/r3_bringup_go.sh" \
  GATE_TRIES=8
```

Follow with (poll interval >= 1 s, precondition 5):

```bash
watch -n 5 'systemctl --user status perballpark-bringup-<timestamp> --no-pager | tail -20'
```

or `journalctl --user -u perballpark-bringup-<timestamp> -f` (line-buffered, no register
reads of its own). Confirm `ARM GATE PASS` and `BRING-UP COMPLETE` before step 3. If the
gate fails after `GATE_TRIES`, do not retry blindly — a failed gate deliberately does not
start the daemons, so no traffic is flowing and nothing downstream can be measured; check
`146 rx=` / `148 rx=` in the log against the arm-lottery and RF-degradation notes in
section 5 before re-running.

## 3. Measure PER, forward leg (146 TX -> 148 RX), >=600 s

`capture_r3.sh` takes positional args (`A|B`, `-d`, `-o`, ...) the same way
`bringup_r2r3.sh` does, so it needs the same one-line wrapper trick as 2a (`launch_rig_unit.sh`
forwards only `K=V` env, never positional args). A `-d 600` run takes ~13-14 min wall time
(`PERF_T = DUR + 140` traffic window plus settle/gate overhead), well past any interactive
shell timeout, so run it as a rig unit, not foreground:

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup
FWDOUT=r3cap/ballpark_fwd_$(date +%Y%m%d_%H%M%S)
cat > r3cap_fwd_go.sh <<EOF
#!/bin/bash
D=\$(cd "\$(dirname "\$0")" && pwd)
exec "\$D/capture_r3.sh" A -d 600 -k -o "\$D/$FWDOUT"
EOF
chmod +x r3cap_fwd_go.sh
LO_A_RX=2000020000 LO_B_RX=1900040000 RXQ=1 GATE_TRIES=8 \
  bash launch_rig_unit.sh perballpark-fwd-$(date +%H%M%S) "$PWD/r3cap_fwd_go.sh"
```

(`LO_A_RX` / `LO_B_RX` / `RXQ` / `GATE_TRIES` are passed as env to the unit, which
`launch_rig_unit.sh` forwards via `--setenv`; `capture_r3.sh` reads them with the same
`${VAR:-default}` fallbacks as `bringup_r2r3.sh`.)

- `A` = capture target board A (148), i.e. the forward leg RX side.
- `-d 600` = 600 s of saturating `qpsk_perf` traffic (146 -> 148 tun) during the capture
  window; `capture_r3.sh` internally pads its own wait/traffic timers (`PERF_T = DUR+140`)
  so the actual air time covered is >= 600 s.
- `-k` = leave the link up afterward, so the reverse-leg capture (step 4) can start
  immediately without a second bring-up.
- `-o` names the output dir explicitly so it's easy to find afterward; omit and it
  defaults to `r3cap/<timestamp>_fwd`.
- `LO_A_RX` / `LO_B_RX` / `RXQ` are re-stated here **only** because `capture_r3.sh`
  re-invokes `bringup_r2r3.sh r3` internally (to build/deploy the frame-logging binary and
  re-arm cleanly with `QPSK_FRAMELOG` set) — passing the shipped-default values keeps this
  invocation identical to the shipped configuration, it does not change anything.
- Do **not** pass `RXONLY` or whiten overrides: `capture_r3.sh` drives the daemons with
  `WHITEN=${WHITEN:-0}` (unwhitened, matching `bringup_r2r3.sh`'s default) and the
  measured frames are real host_seq-numbered `qpsk_tun` traffic (not a BIST reference
  pattern), so RXONLY does not apply to this path — that flag belongs to the R0
  `link_test.sh ber` BIST lineage instead.
- Output lands in `r3cap/ballpark_fwd_<ts>/frames.bin` (per-frame telemetry, 48 B/record)
  plus `qpsk_tun.log`, `meta.txt`, `regs_{pre,cap,post}.txt`.
- Watch (>=1 s polling only) for `CAPTURE_ABORTED_WEDGED` (exit 3) — if it prints, this run
  produced **no usable data**; do not proceed to scoring it, re-run instead.

## 4. Measure PER, reverse leg (148 TX -> 146 RX), >=600 s

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup
REVOUT=r3cap/ballpark_rev_$(date +%Y%m%d_%H%M%S)
cat > r3cap_rev_go.sh <<EOF
#!/bin/bash
D=\$(cd "\$(dirname "\$0")" && pwd)
exec "\$D/capture_r3.sh" B -d 600 -k -o "\$D/$REVOUT"
EOF
chmod +x r3cap_rev_go.sh
LO_A_RX=2000020000 LO_B_RX=1900040000 RXQ=1 GATE_TRIES=8 \
  bash launch_rig_unit.sh perballpark-rev-$(date +%H%M%S) "$PWD/r3cap_rev_go.sh"
```

Same options, `B` = capture target board B (146), i.e. the reverse leg. `-k` again to
avoid a spurious extra teardown/bring-up cycle; tear the link down explicitly after this
one (section 6).

Run steps 3 and 4 **sequentially, not simultaneously**. This matters: the 2026-08-28
bidirectional soak (`SINGLES_CAMPAIGN.md`, Track D4, `soak_bidir.sh`, simultaneous
saturating traffic both directions) measured forward 10.37 % and reverse 8.05 % under
concurrent load — both legs degrade materially versus the sequential single-direction
numbers this runbook reproduces (8.7 % / 1.39 %). Sequential single-leg capture is the
protocol the shipped-default reference numbers were measured with; simultaneous load is a
different, harder measurement regime and would not be comparable to the reference.

## 5. Compute the result

```bash
python3 accept_analyze.py r3cap/ballpark_fwd_<ts>/frames.bin
python3 accept_analyze.py r3cap/ballpark_rev_<ts>/frames.bin
```

What this reports, and why it satisfies "dropped/lost frames in the denominator":

- Each frame's `host_seq` (a monotonically increasing TX-side sequence number, logged into
  `frames.bin` by the frame-logging build) is read for every **clean** (CRC-OK) frame in
  the *live-link window* (excludes the first 15 s settle transient and any trailing wedge
  ramp — `accept_analyze.py:analyze`, `settle_s=15.0`).
- `span = cw[-1] - cw[0]` — the sequence-number range actually spanned, i.e. the **total
  count of frame opportunities that should have arrived** (sent, from the TX-side counter
  reconstructed via the RX-observed sequence numbers) — this is the denominator, and it
  is **not** the count of frames the RX side happened to decode.
- `miss = sum(gap - 1 for each gap > 1 in the sequence)` — CRC failures collapse to a gap
  in the clean-sequence stream exactly the same as a frame that never arrived at all, so
  CRC drops AND framesync misses are both captured by this one gap-counting mechanism.
  `lost/dropped frames are in the denominator` by construction: `span` counts every
  sequence slot from first-seen to last-seen, whether or not a clean frame landed in it.
- `PER = 100 * miss / span` (delivered PER). `CP95UL` = Clopper-Pearson 95 % upper bound on
  that same (miss, span) pair — quote this alongside the point estimate, and note the
  `<1%` gate check in the script's own pooled-output line for reference (not the target
  here, just the same scale the reference numbers use).
- **Sample count to quote:** `span` (the printed `(miss/span)` denominator) for each leg,
  plus the wall-clock `live {live_end:.0f}s/{dur:.0f}s`. At the shipped ~1245 f/s nominal
  and >=600 s of *live* window, expect `span` in the ~700,000+ range per leg — orders of
  magnitude above the skill's 10,000-frame floor.
- If either run prints `UNUSABLE (live window ...)`, that leg produced no usable measurement — do not report a PER for it; re-run.

## 6. August reference numbers to compare against (exact provenance)

| Leg | PER | CP95UL | Command / source |
|---|---|---|---|
| Forward (146->148) | **8.732 %** (7361/84301) | 8.924 % | `RXQ=1 sim_repro/ab_fifo_legs.sh rxq1full` -> `capture_r3.sh A -d 68 -k` (3 legs, image `fe5bd8a4fe19`) + `accept_analyze.py`, run r3 of 3, `SINGLES_CAMPAIGN.md` 2026-08-27 13:1x. Shipped as `RXQ` default 0->1 in `bringup_r2r3.sh` (`QUEUED_RX_MODE_VERDICT.md`). |
| Reverse (148->146) | **1.391 %** (1258/90468) | 1.469 % | Reverse LO sweep, `capture_r3.sh B -d 68 -k`, image `fe5bd8a4fe19`, queued (`RXQ=1`) default, `LO_B_RX=1900040000` (+40 kHz off-null), `SINGLES_CAMPAIGN.md` 2026-08-28 00:4x/01:0x. Shipped as `LO_B_RX` default `1900002500`->`1900040000` in `bringup_r2r3.sh`. |
| No-RF byte-plane starvation | ~5 % | n/a | Sim-only (`rtl_sim/TXPLANE_SIM_RESULTS.md`), TX byte-in `ByteWordBuffer` underrun, netlist-proven, **not an RF/air-link number** — cited only to distinguish a fabric-arrival defect from what this runbook measures over the air. `~/.claude/.../memory/forward-per-two-defects.md`. |

Both reference legs used `-d 68` (single ~70 s capture); this runbook's >=600 s window is
a longer, more statistically solid version of the identical pipeline and configuration —
directly comparable, not a different measurement.

## 7. What would make a run UNINFORMATIVE

- **Link never reaches `ARM GATE PASS`** (section 2) — no traffic flows, nothing to score.
- **`capture_r3.sh` reports `CAPTURE_ABORTED_WEDGED`** (pre-capture) or
  `MID_CAPTURE_WEDGE` (mid-capture) — delivery flatlined below `RATE_MIN` (300 f/s, ~25 %
  of nominal) and re-arms didn't clear it; this is a wedge, not a PER measurement of the
  link's steady state.
- **`accept_analyze.py` reports `UNUSABLE`** for a leg — the live-link window collapsed
  (clean rate never sustained >=25 % of its own peak for long enough after the 15 s
  settle) or fewer than 100 clean frames landed in the window.
- **`span` (sample count) too small** — a short or heavily-wedge-truncated live window
  can leave `span` far below the >=10,000-frame floor; if `live_end` is much less than the
  600 s duration requested, treat the run as informative only about the truncated window,
  and re-run for a full window before reporting a number.
- **A measured PER lands within ~0.2 pp of a threshold you're evaluating against** (e.g.
  the <1 % ARQ gate, or a claimed improvement over the 8.73 %/1.39 % baseline) at this
  sample size — CP95UL will usually resolve it at these frame counts, but if it doesn't,
  extend the capture rather than calling it.
- **RF cabling changed since the reference numbers were taken.** Per `HOSTS.md`: "RF
  cabling changes per experiment — verify before assuming" for the jupiter A/B pair. If
  antenna/cable state is not confirmed identical to the 2026-08-27/28 reference runs
  (antennas were NOT swapped per `on-air-hold-rf-degradation.md`), state that explicitly
  alongside any comparison to the reference numbers — a large deviation could be a cabling
  change, not a link-quality change.
- **Simultaneous bidirectional traffic** — see section 4; this is a different, harder
  regime (measured 8-10 % both directions under load, `SINGLES_CAMPAIGN.md` Track D4) and
  is not comparable to the sequential reference numbers without saying so.
- **148's txfixF3 fix vs the reference image.** The reference numbers (`fe5bd8a4fe19`) predate
  the F3 fix (`f6a8c3ea119c`) now on 148. `TXFIX_STATE.md` §7's internal BIST loopback
  comparison (F3 vs unfixed `638b36de3493`) found the two images statistically identical
  under that (gate-limited, non-RF) test — but that is not evidence about the live-air
  numbers this runbook produces; report the measured forward/reverse PER on today's image
  as its own result, only using the reference table for scale, not as a same-image
  control.

## 8. Teardown

After both legs are scored (or immediately, if this was a diagnostic run with `GATE_HARD=0`
opted out — not used above):

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup
./link_test.sh down   # or: quiesce both boards per capture_r3.sh's own teardown block
                       # (pkill qpsk_tun/lock_watchdog, ip link del tun0, devmem clear)
```

`capture_r3.sh ... -k` (used in steps 3-4) leaves the link up between legs deliberately;
only tear down after step 4's capture is scored, not between forward and reverse.

---
Claude-Session: https://claude.ai/code/session_019NZLGbxoaPRkDnKFMPiBrq
