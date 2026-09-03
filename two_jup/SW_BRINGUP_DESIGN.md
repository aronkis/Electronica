# Software-controlled modem bring-up — design note

Status: **design + evidence, not implemented.** Written 2026-08-06 from campaign data.

## Why

Bring-up today is `bringup_r2r3.sh`: a host-driven shell script that ssh's into both
boards, loads profiles, applies SSI delay overrides, arms ROM, probes the frame rate,
and retries the whole arm on failure. It works, but it is a **lottery with a retry
loop**, and the retry loop is the only thing making it reliable.

### Measured: the arm lottery (n=19 first attempts, this campaign)

| first-try 146 RX rate | count | share |
|---|---|---|
| ~1244 f/s (full)      | 7     | 37%   |
| ~520 f/s (0.42x)      | 10    | 53%   |
| ~886 f/s (0.71x)      | 1     | 5%    |
| <100 f/s (dead)       | 1     | 5%    |

**First-try success is 37%.** Mean ≈ 2.7 arm attempts per bring-up; observed worst case
6 attempts and outright failure (3 of 21 bring-ups failed the gate entirely and needed a
re-run). Each attempt costs ~20 s of probe plus re-arm, so a bad bring-up burns minutes
and, worse, sometimes lands *just above* the gate threshold and proceeds degraded.

### The key structural observation

The outcomes are **discrete, not continuous**: 0.42x, 0.71x, 1.0x of nominal. Analog RF
margin would produce a smear. Discrete levels point at a **state-capture defect** — the
receive path latching into one of a small number of wrong states at arm time (SSI lane
or phase capture, or an enable-domain alignment), each of which decodes a fixed fraction
of frames.

This matters for the design: if the bad states are *identifiable*, bring-up can stop
gambling and start **diagnosing**.

Note also: 2439 f/s (2x nominal) appeared once — that is the sps=8 geometry signature,
i.e. a wrong-image tell, not a rate. Bring-up should recognise it explicitly rather than
treat it as "high".

## What software-controlled bring-up should be

Move from *host script that retries* to an **on-board service that converges**.

### 1. On-board, not over ssh
Bring-up currently runs from the host across ~30 ssh round-trips per attempt, which is
why it is slow and why an interrupted host leaves the board half-armed. A small daemon on
each board owns its own bring-up and exposes state; the host asks for a rung and polls.

### 2. Deterministic state classification, not a pass/fail probe
Replace "measure rate, retry if < threshold" with: measure rate, **classify** into
{FULL, 0.71x, 0.42x, DEAD, WRONG-GEOMETRY}, and take the recovery action matched to that
class. Today every failure gets the same blunt full re-arm.

### 3. Targeted recovery per class
- **0.42x / 0.71x** — suspected SSI capture state. Recovery: re-apply the SSI delay
  override and re-arm *without* a profile reload (cheap, seconds).
- **DEAD** — suspected LO/ensm or profile problem. Recovery: full profile reload path.
- **WRONG-GEOMETRY (2x rate)** — do not retry at all; fail loudly, it is a wrong image.
- **FULL** — proceed; record the SSI delay values that produced it.

### 4. Learn the good state
Every successful arm records its SSI delay pair and profile in a small on-board file.
Next bring-up starts from the last known-good values instead of the driver's auto-tune.
This is the single highest-value change if the discrete-state hypothesis holds.

### 5. Absorb the existing hard-won rules
- Kill every `direct_reg_access` poller **before** a profile reload (this hung both
  boards twice; the rule currently lives in a comment in `arm_rom`).
- Never `pkill` with a pattern that matches the remote command line.
- SSI overrides do not survive a profile reload — re-apply after, always.
- Stream-first arm ordering, double-tap, and the byte re-arm sequence are load-bearing.

## The experiment that should come first

Before building the service, test the discrete-state hypothesis — it is cheap and it
decides whether classification is even possible:

1. Arm 20 times, recording for each: the 146 RX rate **and** the live SSI delay readback
   (`tx0/rx0 clk/data`) plus the ensm states, immediately after arm.
2. Ask: does the ~0.42x cluster correlate with a specific SSI delay pair, or a specific
   ensm/profile state?
   - **Correlates** → the fix is deterministic: force the good state, no lottery. The
     service becomes simple and bring-up becomes ~100% first-try.
   - **No correlation** → the bad state is internal to the fabric/SSI capture and not
     visible in the register set; the service still helps (fast targeted re-arm, learned
     good values) but cannot eliminate the retry.

Caveat worth stating: `SSI146="5 4"` (an explicit delay override) is *already* used in
every bring-up above, and the lottery persists. So either the override is not the
relevant state, or it is being applied at the wrong point in the sequence. The experiment
above distinguishes those.

## Scope estimate

- Hypothesis experiment: ~1 h of board time, no rebuild, no flash.
- Service prototype (Python, on-board, systemd-less like the rest of the rig): ~1 day,
  no fabric changes.
- Keeps `bringup_r2r3.sh` as the fallback path until the service proves out.

## SSI delay: use the driver's BIST, but not alone (added 2026-08-06)

The ADRV9002 driver exposes a full SSI test-mode interface per channel (debugfs
`iio:device2`), confirmed present on 146:

- data patterns: `NORMAL`, `FIXED_PATTERN`, `RAMP_16_BIT` (rx only), `PRBS15`, `PRBS7`
- `tx0_ssi_test_mode_fixed_pattern` (a single programmable value)
- `tx0_ssi_test_mode_loopback_en`
- **`tx0_ssi_test_mode_status` -> `dataError`, `fifoFull`, `fifoEmpty`, `strobeAlignError`**
- delay controls: `{rx,tx}{0,1}_ssi_{clk,i_data,q_data,strobe,refclk}_delay`, plus the
  `ssi_delays` apply-all

### The blind spot (already paid for, do not re-learn)
The driver's per-boot 8x8 auto-tune IS this BIST, scored with PRBS. TXCHAR proved PRBS
is **blind to I/Q lane duplication**: 146 radiated Q = copy-of-I and PRBS passed, because
each lane independently carried valid PRBS. The auto-tune chose tx0_ClkDelay=2, which is
exactly the slip point; the mission-mode 2D sweep found the true point (clk=3/data=4).
`FIXED_PATTERN` and `RAMP` inherit the same blind spot -- there is ONE pattern attribute,
so both lanes carry the same data and duplication stays invisible. **No SSI BIST mode can
detect lane duplication; only mission-mode (independent I and Q) can.**

### Where BIST is genuinely better than what we do now
`strobeAlignError` is an explicit, discrete alignment fault, readable in milliseconds.
That is the same shape as the measured arm anomaly (discrete plateaus 0.42x/0.71x/1.0x,
not an analog smear). If it correlates with the 0.42x cluster we get DETERMINISTIC
detection of the bad arm state, instead of inferring it from a 5 s frame-rate probe.

### Proposed two-stage delay selection
1. **Fast BIST screen** -- PRBS15, read `*_test_mode_status`, reject any delay point with
   `strobeAlignError` or `dataError`. Deterministic, ms per point; can sweep the whole
   8x8 grid in less time than one current probe takes.
2. **Mission-mode confirmation** on survivors -- ROM BIST golden compare or frame rate.
   Non-negotiable: this is the only stage that catches I/Q duplication.
3. **Persist the winner** and start there next boot instead of re-running auto-tune.

### Cautions
- Test mode takes the data path out of normal operation: bring-up only, NEVER against a
  live link or an active soak.
- SSI delay writes hit the cache-clobber footgun: live-read seed -> override -> apply ->
  verify by readback, or a partial write silently zeroes the other delays.

### Revised first experiment
Fold this into the 20-arm experiment: after each arm, record the rate AND
`{rx0,tx0}_ssi_test_mode_status` alongside the delay readback. If `strobeAlignError`
tracks the fractional-rate clusters, the bring-up app can classify deterministically and
the retry lottery goes away.

## RESULT OF THAT EXPERIMENT — the null branch (run 2026-08-07, n=16)

**`two_jup/armstat/v2_20260807_000403/`.** 16 arms at `GATE_TRIES=1` on the combined
T9.0 image. Outcome distribution FULL 6 (38%) / 0.71x 1 (6%) / 0.42x 9 (56%) — a close
match to the historical 37/5/53, so the lottery is stable across images and days.

**Nothing in the driver register set separates the outcome classes.**

| field | FULL | 0.42x | separates? |
|---|---|---|---|
| rx0 clk/i/q/strobe delay | 0/4/4/4 | 0/4/4/4 (8), 0/3/3/3 (1) | no |
| tx0 clk/i/q/strobe delay | 5/4/4/4 | 5/4/4/4 | no (constant) |
| tx0 `strobeAlignError` | 0 (4), 1 (2) | 0 (7), 1 (2) | no |
| rx0 `*_test_mode_status` | *empty* | *empty* | unavailable |

Two caveats that matter more than the table:

1. **The status fields were not validly sampled.** `dataError: 1` on all 16 arms —
   including every FULL one — means the register was read *outside test mode*, where its
   contents have no defined meaning. `strobeAlignError`'s 0/1 variation inherits that.
   A future attempt must enter test mode first; until then these rows are uninformative
   rather than negative.
2. **RX status is entirely unavailable** (`rx0_ssi_test_mode_status` reads empty), and RX
   is the end where the degradation lives. The proposed fast-BIST screen can therefore
   validate the transmit direction only.

Per this note's own decision rule, this is the **"No correlation"** branch: the bad state
is internal to the fabric/SSI capture and not exposed in the register set. **Classification
cannot eliminate the retry lottery.** The service is still worth building for fast targeted
re-arm, learned-good values, and absorbing the hard-won rules — but section 2's
"deterministic state classification" must be demoted from the headline feature to a
best-effort heuristic, and section 4 ("learn the good state") becomes the primary value.

### The one actionable finding: the override pins the wrong end
`apply_146_ssi_fix.sh` overrides **tx0 only**; it explicitly *preserves* rx0 from the live
read, i.e. carries forward whatever that boot's auto-tune chose (verified in the script's
step (e), which asserts rx0 is unchanged). So `SSI146="5 4"` pins the transmit side while
**the receive side re-runs auto-tune on every arm** — and the receive side is where the
degradation is. This is a direct answer to the caveat raised above ("either the override is
not the relevant state, or it is applied at the wrong point").

It did **not** separate the classes here — 8 of 9 degraded arms had the same rx0=0/4/4/4 as
every FULL arm — so it is not the whole story and should not be oversold. But pinning rx0
explicitly is cheap, needs no rebuild, and is the obvious next experiment.
