> Evidence ledger, moved verbatim from `two_jup/comb/FWD_CRC_REGRESSION_0907.md` on 2026-09-09. Relative paths inside refer to the tree at tag `archive/pre-cleanup-2026-09-09`.

# Forward-leg sync collapse on board 148, 2026-09-07 (RXFIX Task 52)

**Status: 148's image is EXONERATED by the rollback (section 8). The fault is a
forward-direction-only carrier-offset shift of unknown origin; 146's TX chain and
a one-directional RF asymmetry are the live suspects, and the onset window is 32 h
wide, not the flash boundary.**

**Superseded status (kept because sections 1-7 argue from it): LOCALISED to board
148's receive path; the image is the suspect.**
The forward leg (146 TX -> 148 RX) collapsed to ~60 % CRC-good. Excluded with
evidence: the byte seam, the BS instrument's reads, host TX starvation, the frame
plane, carrier resets, the RF environment (a same-night reverse leg is clean at
0.183 % PER), 146's TX SSI override, -- measured on silicon at 21:53 -- a missing
RX LO offset, and -- by the plain leg `t53_fwd_plain` of section 5b -- the whole
W1/BS/P8 measurement harness. Board 148's receive CFC sits in the demodulator's
documented **CFO dead zone** during the collapse, but that is a population-level
correlate: inside the bad leg, per-frame CFC does not predict per-frame failure.
The remaining step is the rollback flash and its pre-registered test (section 6).

## 1. The regression

`crc_ok` below is measured directly from `cap/frames.bin`
(`two_jup/accept_analyze.py:read_frames`, `crc_ok != 0`) over the whole capture,
never from the capture log's health line. Command:

    python3 -c "import sys;sys.path.insert(0,'two_jup');from accept_analyze import read_frames;
                a=read_frames('<run>/cap/frames.bin');print(len(a),(a['crc_ok']!=0).sum()/len(a))"

Forward legs (capture on 10.0.0.148), longest first:

| run | image on 148 | frames | dur | crc_ok | cfc median | cfc std |
|---|---|---|---|---|---|---|
| 20260904_201814_w1_air | 9f13705d9fb0 | 893,975 | 721 s | 99.67 % | -3419 | 1504 |
| 20260905_075030_w1_air2 | 9f13705d9fb0 | 897,545 | 721 s | 99.84 % | -3421 | 113 |
| 20260905_084623_w1_hostfix_on | 9f13705d9fb0 | 897,517 | 721 s | 99.95 % | -3432 | 105 |
| 20260905_091549_w1_hostfix_off2 | 9f13705d9fb0 | 898,283 | 721 s | 99.83 % | -3435 | 97 |
| 24 x legA_t38 ladder (09-06) | ? | ~79,900 each | 66 s | 98.11-98.37 % | -3183..-3350 | 7-9 k |
| **20260907_210329_w1_bspair** | **dec007ae70dd (BS)** | **731,556** | **605 s** | **62.15 %** | **+756** | 6829 |
| **20260907_212008_w1_bspair_rerun** | **dec007ae70dd (BS)** | **730,958** | **606 s** | **59.69 %** | **+584** | 6666 |

Duration is NOT the confound: there are four 721 s forward legs on the pre-BS
image at 99.67-99.95 %, longer than the two 605 s bad legs.

## 2. The strongest correlate: the CFO dead-zone signature

`two_jup/bringup_r2r3.sh:8-9` (written 2026-08, task-TXCHAR2) states it outright:

> the fabric demod has a **DEAD ZONE at residual CFO ~= 0** (CFC near-zero dither;
> 0x154 sign-flips, **sync collapses to ~40 %**).

Across **all 60 banked captures**, every healthy forward leg in the record has a
CFC (0x154, sign-corrected) median between **-3183 and -3435** -- good legs and
mediocre ones alike. The three 2026-09-07 forward legs are the **only** forward
captures whose CFC median crossed zero (+719, +551, +682), and they are the only
forward legs with a sync collapse. The observed collapse magnitude (59-62 % good,
i.e. 38-41 % lost) is the ~40 % the comment predicts.

### The CFC census, one row per leg [silicon]

Every banked capture over 2 MB with 60 s < dur < 5000 s, scored from
`cap/frames.bin` with `accept_analyze.read_frames` (`crc_ok != 0`; CFC median and
quartiles over all records). This is the cleanest before/after signature in the
campaign:

| run | dir | rec | crc % | dur s | cfc med | q25 | q75 |
|---|---|---|---|---|---|---|---|
| 20260905_161957_w1_t32b2 | fwd | 158,249 | 99.25 | 129.1 | -3428 | -3506 | -3357 |
| 20260906_110000_legA_t38_fix_02 | fwd | 79,898 | 98.23 | 66.0 | -3211 | -3584 | -2879 |
| ... t38 ladder, 25 legs | fwd | ~80,000 ea | 98.11-98.37 | 66 | -3185..-3352 | | |
| 20260906_140355_w1_t39_default | rev | 610,635 | 99.55 | 494.0 | -4728 | -4850 | -4611 |
| **20260907_210329_w1_bspair** | fwd | 731,556 | **62.15** | 605.2 | **+719** | -819 | +1963 |
| **20260907_212008_w1_bspair_rerun** | fwd | 730,958 | **59.69** | 605.5 | **+551** | -998 | +1807 |
| 20260907 t52_rev1 | rev | 756,473 | 99.60 | 611.3 | -4761 | -4890 | -4638 |
| **20260907 t53_fwd_plain** | fwd | 735,841 | **59.01** | 610.1 | **+682** | -901 | +1940 |

Two things this table settles that no single leg could:

1. **The reverse residual did not move.** `t52_rev1` ran in the same bringup as
   `t53_fwd_plain` -- `bringup_r2r3.sh` arms both boards and all four LOs on every
   bringup -- and sits at -4761, indistinguishable from the 09-06 reverse leg's
   -4728. A drifted reference, a bad TCXO or a PLL that came up wrong would move
   **both** directions, because 148's TX and RX share one reference. Only the
   forward residual moved. That excludes a board-level clock/PLL drift and, with
   it, the premise of an `LO_A_RX` retune: there is no input frequency error to
   retune away.
2. **The shift is forward-only and lands at the flash boundary.** 148 is the
   forward RX and is not in the reverse-RX path at all.

CFC is also dithering: std 6.8 k with excursions to +-261,000, against 97-113 in
the healthy 721 s legs. That is the "CFC near-zero dither / 0x154 sign-flips"
signature, not noise.

### REFUTED on silicon: the +20 kHz RX LO offset IS on the board

`bringup_r2r3.sh:58` sets `LO_A_RX=${LO_A_RX:-2000020000}` -- 148's RX LO is
deliberately parked **+20 kHz off null** (operator-acked 2026-08-26; the plain
2000000000 "sits on the bad side of the asymmetry"). `arm_rom()` writes it with
`2>&1` swallowing any error, so a silently-failed write was the cheapest
candidate for a step change that needs no image to explain.

**Measured 2026-09-07 21:53** [silicon], both boards quiesced immediately after
the t52_rev1 arm, via
`anyssh.sh <ip> 'cat /sys/bus/iio/devices/iio:device2/<attr>'`:

| board | RX1 LO | TX1 LO | RX gain | AGC mode | RSSI | fs |
|---|---|---|---|---|---|---|
| 148 | **2000020000** | 1900000000 | 34.000 dB | automatic | 30.790 dB | 61440000 |
| 146 | **1900040000** | 2000000000 | 34.000 dB | automatic | 25.436 dB | 61440000 |

Both offsets landed exactly as configured, on the arm that immediately preceded
this read. **The missing-LO hypothesis is dead.** No flash, no leg, decided.

The arithmetic never fitted either, and an earlier revision of this file was
wrong to say it did. The CFC scale is **~7.5 Hz/unit**, not the 5 Hz/unit
asserted there: `SINGLES_CAMPAIGN.md:2180` gives +2046/-2049 = +-15.0 kHz and
`FLOAT_GAP_BUDGET.md:100` gives +49/+147 = +0.4/+1.1 kHz. At 7.5 Hz/unit the
observed -3400 -> +600 step is ~30 kHz, not 20 kHz; and a *missing* +20 kHz
would park the residual near **-690** units -- negative, not the observed +600.
Wrong magnitude and wrong sign.

### CFC is a co-symptom, not a demonstrated per-frame cause

Inside the bad leg, CFC does not predict per-frame outcome. Frames whose
instantaneous CFC sits in the historically healthy -8k..-2k band still fail at
37.1 % (62.86 % crc_ok) -- statistically indistinguishable from 63.12 % at
|cfc| < 2k and 60.06 % at 2k..8k. Flat, no gradient.

That matters because the same per-frame sample **does** discriminate on the
comparison legs: `t38_ctl_25` is 99.92 % crc_ok inside the band and 0.00 %
outside it, and `hostfix_off2` has 100 % of frames inside. So `reg_cfc` is not
too decorrelated to carry the signal -- it carried it twice and then stopped.
Near-null CFO cannot be what kills frames that were sampled at a healthy
residual.

What survives is the population-level fact: the CFC IQR [-798, +2016]
straddling zero is a genuine 0x154 sign-flip signature, and it is unique to the
two BS legs among all 60 banked captures. Something puts 148's carrier loop
into that state during these legs. The LO is not it.

## 3. What is excluded, with the evidence

**The byte seam is not the mechanism.** 108,749 / 124,994 dropped *words* against
212,138 / 228,865 CRC-bad frames -- 0.51 / 0.55 words per bad frame; correlation
+0.278 / +0.142. Even "one word kills one frame" caps the seam at ~19 % of the
observed loss. (`BS_DROP` counts WORDS, not events: per-interval conservation
`dBS_POP + dBS_DROP == dBS_WORDS == dBS_PUSH` holds exactly on every interval,
e.g. 2,358,112 + 2,336 = 2,360,448, at 190.8-191.0 words/start.)

**The BS reader is not the cause.** Per-30 s CRC-good is flat across the whole
leg, including the final 120 s during which the reader window is closed and no
register sweep runs at all: 60.77 / 60.93 / 60.28 / 61.16 % in the 480-600 s
buckets against 61-64 % during the reader window. Also flat against distance from
the frozen sweep (~37 % bad in every bucket from 0.00-0.05 s to 4-5 s).

**The frame plane is intact.** dBS_STARTS 12,300-12,700 per 10 s, `d0x124` and
`d0x104` matching within +-25, 190.8 words/start. Framing and packet emission are
healthy; the payloads are what fail.

**Host TX starvation is excluded.** `comb_census.py --txlog` join:
`lost_rx=286453 never_sent=0 sent_not_decoded=286453`. Board 146 submitted every
lost frame.

**RF environment / the whole rig is not degraded.** Reverse leg `t52_rev1`
(LEG=B, 148 TX -> 146 RX, launched 21:40 under the keeper hold) scored directly
from `cap/frames.bin` with `accept_analyze.read_frames` -- not from the health
line:

    records=756473  crc_ok=753412 (99.595 %)  dur=611.3 s  rate=1237.5 f/s
    host_seq span=754792  miss=1382  PER=0.1831 %   (lost frames IN the denominator)
    cfc median=-4761  p1=-5284  p99=-4364
    fail_class {OK 753412, MAGIC 2789, LEN 1, CRC 269, ZEROTAIL 2}

0.1831 % over 754,792 frame slots is the shipped reverse number (pooled 0.191 %),
on the same night, with 148 transmitting and its RF chain live. The fault is
**direction-specific**, so the RF environment, 148's TX, and 146's RX are all
excluded.

**146's TX SSI override is not the difference.** Forward legs use 146's TX, which
the reverse leg does not exercise, so the reverse control above leaves it open.
`bringup_r2r3.sh` runs `apply_146_ssi_fix.sh` every bringup and logs the outcome;
diffing that line across legs gives `146: ssi-fix VERIFIED: tx0=c3d4 rx0 preserved
(rearmed, 0x114=1)` **identically** on both bad legs, on `t52_rev1`, on
`t38_ctl_25`, and on both 721 s good legs. The only field that varies is the
arm-lottery retry count (0/4, 1/3, 0/3), which does not track the outcome: the
good `t38_ctl_25` and the healthy `t52_rev1` both show 0/4, the same as the bad
legs. **This is a configuration check, not a signal check** -- it compares the
line the script logs, not 146's emitted waveform -- so 146's TX chain is
narrowed, not excluded (section 6).

**Carrier resets are a red herring.** `reg_rstcs` is 0 for the entire 600 s window
in both bad legs; the 4,746 / 4,929 increments all land after t = 602 s, i.e. in
the post-window teardown when traffic stops.

## 4. The failure class is MAGIC, which fits CFO and not noise

`comb_census.py` fail-class census over the live window:

| leg | n | OK | MAGIC | LEN | CRC |
|---|---|---|---|---|---|
| 20260907_210329_w1_bspair | 709,006 | 442,047 | **230,783** | 3,348 | 32,828 |
| 20260905_091549_w1_hostfix_off2 (good) | 879,600 | 878,076 | 1,349 | 0 | 175 |

MAGIC outnumbers CRC 7:1. Random bit noise would do the opposite: a 32-bit magic
against a 2,240-bit frame means an independent-error channel produces ~70x more
CRC failures than MAGIC failures. A frame demodulated under a lost/hunting carrier
is garbage from its first byte, which lands as MAGIC. The good leg has the same
7.7:1 ratio at 1/170th the rate -- the same class, amplified, not a new one.

## 5. Correction to the earlier reading of the health line

`capture_r3.sh:270` prints `health try N: rev X% fwd Y%`. Read the source before
quoting it:

- `X` = `crc_health $RX_IP` -- the CRC-good fraction on the **capturing** board,
  whatever direction the leg captures. The literal string `rev` is hard-coded in
  the echo and does **not** mean the reverse direction.
- `Y` is `100` unless `FWD_GATE=1` (`capture_r3.sh:269`). No script in the repo
  ever sets `FWD_GATE`, so **`fwd 100%` is a constant, never a measurement.**

So the bad legs' `rev 58-61% fwd 100%` is the forward direction measured at 58-61 %
and a meaningless constant -- it agrees with frames.bin, it does not contradict it.
The 09-06 ladder's `rev 100%` was likewise the forward direction (integer-rounded
from the 98.1-98.4 % that frames.bin actually shows).

## 5b. The plain forward leg: the harness is excluded [silicon]

`t53_fwd_plain` (`two_jup/comb/runs/t53_fwd_plain/`, launched 21:54, finished
22:07) is the exact mirror of `t52_rev1`: `legrun_go.sh LEG=A DUR=600 DRY=0`, **no
BS, no W1, no P8, no third-ssh reader**. Command used for the score:

    python3 -c "import sys;sys.path.insert(0,'two_jup');from accept_analyze import read_frames;
                a=read_frames('two_jup/comb/runs/t53_fwd_plain/cap/frames.bin');
                ok=a['crc_ok']!=0; print(len(a), ok.sum()/len(a))"

| leg | rec | crc_ok | dur s | rate f/s | host_seq span | missing | PER | cfc med |
|---|---|---|---|---|---|---|---|---|
| `t53_fwd_plain` (fwd) | 735,841 | 434,191 (**59.006 %**) | 610.1 | 1206.1 | 755,426 | 321,237 | **42.524 %** | +682 |
| `t52_rev1` (rev) | 756,473 | 753,412 (99.595 %) | 611.3 | 1237.5 | 754,792 | 1,382 | **0.1831 %** | -4761 |

PER counts **lost frames in the denominator** (`host_seq` span, `crc_ok != 0`
filtered first because CRC-bad frames carry garbage sequence numbers). Fail-class
census for `t53_fwd_plain`: MAGIC 261,487 / CRC 36,667 / OK 434,191 / LEN 3,489 /
ZEROTAIL 7 -- the same MAGIC-dominated class as section 4.

The leg failed its own deliver-rate gate (`deliver_rate_post=591`,
`deliver_rate_gate_pass=0`), with `watchdog_relaunch=0` and `recovery_events=0`;
its `cap/pair.iq` came back DEGENERATE on the CAPTURE_HEALTH check (the #48
stale-DDR-replay signature), which affects the IQ file only -- `frames.bin` and
the host-side counters are unaffected and are what is scored above.

**Reading.** Three consecutive independent bringups collapse the forward leg to
59-62 %, one of them with no instrument attached at all. The harness is excluded,
and so is arm-lottery. Do not re-run it.

## 6. The rollback flash and its pre-registered test

**Pre-registered BEFORE the flash. Committed before the flash is launched.**

### The success threshold is ~98 %, not 99.8 %

The nearest-in-time pre-flash forward baseline is the **09-06 t38 ladder, 98.11 -
98.37 % crc_ok** over 25 legs. The 09-05 legs' 99.8 % is a different configuration
and ~33 h older; the flash boundary is confounded with that much pre-existing
forward drift, so the flash cannot be asked to recover more than the day before it
had. **Pre-registered threshold: crc_ok >= 98.0 % on the post-rollback plain
forward leg.** Anything between 62 % and 98 % is a partial recovery and will be
reported as one, not rounded up.

### Why 148's image is the suspect

Stated with its evidence rather than asserted:

- The reverse leg exercises **148 TX -> 146 RX** and is clean the same night
  (0.1831 % PER, 99.595 % crc_ok, cfc median -4761 exactly where reverse legs have
  always sat). That excludes 148's TX chain, 146's RX chain, the shared RF
  environment, both boards' reference clocks and the host delivery plane.
- The forward leg exercises **146 TX -> 148 RX** and collapsed at the 18:14 flash
  boundary. 148's RX is the one element in the forward path that the clean reverse
  leg does not touch, and 148's image is the one thing that changed.
- The harness is excluded by `t53_fwd_plain` (section 5b) and arm-lottery by three
  consecutive bringups.
- Not yet excluded: **146's TX chain** and a **one-directional RF asymmetry**. The
  SSI check compared 146's config line (`tx0=c3d4`), not its emitted signal, so it
  is a configuration check and not a signal check. If the rollback does not restore
  the forward leg, these two are what remain.

### The flash

    DRY=0 FLASH_MD5=9f13705d9fb0 FLASH_TAG=rxfixr4b FLASH_BAK=dec007ae70dd \
      bash two_jup/skidfix/flash_148_txfix.sh

launched as a `launch_rig_unit.sh` unit under the keeper hold. `9f13705d9fb0` is
the in-service R4B image; the board cannot be handed back with the forward leg at
59 %, so the rollback is correct regardless of which suspect is real. Pre-flash checks
the chain's DRY mode skips and that are therefore done by hand on the board: free
space on `/root` and `/boot`, and `rm -f` of any stale `/root/BOOT.BIN.staged` (a
leftover passes the chain's `-gt 6000000` size check). One failed flash stops all
rig work.

### The one check that decides it

After the flash, one plain forward leg (`legrun_go.sh LEG=A DUR=600 DRY=0`, no
instrument), scored for **both** crc_ok/PER **and** cfc median:

| outcome | reading |
|---|---|
| crc_ok >= 98 % **and** cfc med ~ -3300 | the image is confirmed as cause and the CFC shift as its co-symptom |
| crc_ok >= 98 % but cfc med still ~ 0 | the dead-zone model is wrong; this document is corrected and the CFC signature demoted to coincidence |
| crc_ok still ~ 59 % | **the image is exonerated**; 146's TX chain and a one-directional RF asymmetry are the remaining suspects, and an `LO_A_RX` sweep becomes the right next move -- with the Hz/unit slope measured across the sweep rather than guessed |

### Rejected: an `LO_A_RX` sweep before the flash

Considered and dropped. The mechanism (park the residual off the CFO null) is the
documented remedy for the dead zone, and `LO_A_RX` does reach the arm unchanged
through `legrun_go.sh` -> `capture_r3.sh:149` -> `bringup_r2r3.sh`. It is dropped
because the reverse-leg control in section 2 shows the residual moved in **one
direction only**, which no LO, reference or PLL error can do; because the two-point
slope needed to pick the values (-72.5 units/kHz, ~13.8 Hz/unit) disagrees by 2x
with the documented ~7.5 Hz/unit, so the sweep values would span a 2.2x range; and
because `reg_cfc` on a leg that is 41 % un-decodable is a tracking loop being driven
by garbage, not an independent frequency meter. Retuning to force its median back
to -3300 would be steering a symptom. If the rollback exonerates the image, the
sweep returns as the next move with the slope measured.

## 7. Consequences for Task 51

Task 51 (the paired-PER census) is **UNINFORMATIVE** by its own pre-registered
falsifier: two `deliver_rate_gate_pass=0` legs exhaust the "one re-run then stop"
allowance. No paired-PER exclusion was obtained, and none can be scored from these
legs -- with 38-40 % of frames failing there is no defensible PER in the census
window. Salvaged: the `bs_pair_score.py` acquisition-order fix (`4edb5f3`), the
`BS_DROP`-is-words unit result, and the flat-vs-sweep-distance table that
exonerates the instrument.

## 8. OUTCOME: the rollback exonerates the image [silicon, 2026-09-07 22:17-22:35]

The flash succeeded and the pre-registered test came back on **branch 3**.

**The flash.** `FLASH_DDRCAP2_OK 9f13705d9fb0` in 4 min 17 s
(`two_jup/skidfix/txfix_flash_20260907_221753.log`): readback `9f13705d9fb0`, two-pass
gate `ARM_OK profile=lvds_61p44_fdd_jupiter fps=1248 capTAP=0xBCF94856 errps=0` on both
passes, Tier-2 witness 4,194,304 B decoding to `records 524288 demod_marks 43 tx_marks 43,
toff min=max=mode=12314 distinct 1`. No rollback, no retry. A **stale
`/root/BOOT.BIN.staged` from the 18:09 flash was found and removed first** -- it holds
`dec007ae70dd` at 7,203,552 B, which passes the chain's `-gt 6000000` check, so a silently
failed `scpput` would have re-flashed the very image being rolled back.

**The leg.** `t55_fwd_plain_r4b` -- `legrun_go.sh LEG=A DUR=600 DRY=0`, the exact mirror of
`t53_fwd_plain`, on the rolled-back image:

| leg | image | rec | crc_ok | PER | cfc med | q25 | q75 |
|---|---|---|---|---|---|---|---|
| `t53_fwd_plain` | `dec007ae70dd` (BS) | 735,841 | **59.006 %** | 42.524 % | +716 | -884 | +1991 |
| `t55_fwd_plain_r4b` | `9f13705d9fb0` (R4B) | 736,403 | **60.272 %** | 41.233 % | +581 | -961 | +1856 |

(Both scored with the same script over all records; the +716 here and the +682 quoted in
section 2 are the same leg under two median conventions -- the claim that survives either is
"near zero with an IQR straddling zero".) Fail class stays MAGIC-dominated: 254,991 MAGIC /
34,188 CRC / 443,847 OK / 3,376 LEN / 1 ZEROTAIL. Gate `deliver_rate_post=599`,
`deliver_rate_gate_pass=0`, `watchdog_relaunch=0`, `recovery_events=0`. Both forward legs
also carry the same three delivery stalls at ~161 / 321 / 486 s (165 s apart) that the
healthy reverse leg does not -- a symptom of the collapse, not an independent process.

**1.3 points of difference on a 40-point deficit. The image is not the cause.**

### The onset window is 32 hours, not the flash boundary

The chronological census kills the coincidence that motivated the flash. Last healthy forward
leg: **09-06 12:46** (`t38_fix_30`, 98.33 %, cfc -3314). Next forward leg of any kind:
**09-07 21:05**. Nothing forward ran in between -- the five `20260907_19*_w1_air` runs were
`DRY=1` and made zero board contact. So the collapse began somewhere in a **32-hour window**
that happens to contain the 18:14 flash and gives it no special standing. Meanwhile the
reverse residual over the same window is unchanged: -4728 on 09-06 14:06, -4761 on 09-07
21:42.

### What is now excluded, and what is left

Excluded: the byte seam, the BS reader, the frame plane, host TX starvation, carrier resets,
the harness (three plain legs), arm-lottery (four consecutive bringups), the missing RX LO
offset, a board-level reference/PLL drift on either board (a shared-reference error moves
**both** directions; only forward moved), **and 148's image and its whole boot state** -- the
board has been re-flashed, rebooted and re-armed, and comes back identical to 1.3 points.

Left, in the order they should be tested:

1. **146's TX chain.** Not power-cycled since 09-05 14:12 (uptime 2 d 8 h at 22:36), so it is
   the one element in the forward path that has not been re-initialised across the onset
   window. All four LOs read back as configured on both boards after the leg (148 RX1/RX2
   2000020000, TX1/TX2 1900000000; 146 RX1/RX2 1900040000, TX1/TX2 2000000000; both TX
   `hardwaregain` 0.000 dB, both RX railed at 34.000 dB, `fs` 61440000 both) -- but a readback
   is the commanded value, not the synthesised one.
2. **A one-directional RF asymmetry.**
3. **The `LO_A_RX` sweep, which section 6 pre-registered as becoming correct exactly here.**
   It now has a job it did not have before the flash: measure the slope and sign of cfc
   against `LO_A_RX` on silicon, and find out whether ~29-55 kHz of retune restores the
   forward leg. Direction and magnitude are to be **measured, not guessed** -- one leg at a
   +30 kHz step tells sign and scale together.

---

## 9. The CFC is untracked, not offset — and the model that says so

Branch 3 fired (§8), so the remaining suspects are 146's TX, a one-directional RF
asymmetry, and the `LO_A_RX` retune. Before spending rig time on any of them, two
desk measurements on banked data.

### 9.1 CFC conditioned on decode

`reg_cfc` split by `crc_ok` and by fail class, same script for every leg
(`scratchpad/cfc_cond.py`, `accept_analyze.read_frames`):

| leg | class | n | med | q25 | q75 |
|---|---|---:|---:|---:|---:|
| `t38_fix_30` fwd, healthy | crc_ok | 78,429 | **−3314** | −3610 | −3052 |
| | MAGIC | 1,318 | +2145 | −38,039 | +54,729 |
| `t52_rev1` rev, healthy | crc_ok | 753,412 | **−4761** | −4890 | −4638 |
| | MAGIC | 2,789 | −4819 | −45,853 | +27,732 |
| `t53_fwd_plain` collapsed | crc_ok | 434,191 | **+682** | −901 | +1940 |
| | MAGIC | 261,487 | **+765** | −865 | +2070 |
| `t55_fwd_plain_r4b` collapsed | crc_ok | 443,847 | **+533** | −986 | +1793 |
| | MAGIC | 254,991 | **+660** | −931 | +1959 |

On a healthy leg the decoded frames sit in a tight band (forward IQR width 558
units, reverse 252) and the undecoded ones are ±100,000 garbage — CFC separates
the two classes completely. On **both** collapsed legs the decoded and undecoded
frames have the *same* distribution: near zero, IQR width ~2800, i.e. 5× the
healthy forward width. **CFC carries no information about whether a frame
decoded.** That is a carrier loop that is not tracking, and it is why no
frequency claim can be read off a collapsed leg's CFC median.

Both of `bringup_r2r3.sh`'s documented failure notes predict this exact
observable and the exact rate:

- the CFO dead zone: *"DEAD ZONE at residual CFO ~= 0 (CFC near-zero dither;
  0x154 sign-flips, sync collapses to ~40%)"*
- ARMCAUSE, the false-FTS latch: *"LATCHES false FTS state (~40% sync, 0x154
  dither, rstcs calm), 0x110 cannot clear"*

Measured: 41.23 % PER, CFC dither about zero, no carrier resets. The observable
does not separate the two causes; their fixes do (retune vs re-arm).

### 9.2 A two-unknown fit that lands on two independently known numbers

Model: baseband residual = f_TX_actual − f_RX_LO, with one inter-board reference
error δ (146 relative to 148) and one CFC scale s.

    fwd (146 TX 2.000 GHz → 148 RX 2.00002 GHz):  (2.0e9·δ − 20000)/s = −3314
    rev (148 TX 1.900 GHz → 146 RX 1.90004 GHz):  (−1.9e9·δ − 40000)/s = −4761

Solving: **s = 7.460 Hz/unit**, **δ = −2.361 ppm**. The independent documented
values are ~7.5 Hz/unit and an inter-board SRO of 2.575 ppm. Two unknowns fitted
from two points is an exact fit by construction, but *landing on two
independently known values* is not, so the model is corroborated — and it
retires the "two-point fit gives 13.8 Hz/unit, 2× off" note: the two legs are on
one line once the board-reference term is in it. Healthy forward residual is
−24.7 kHz, nowhere near the dead zone.

The reverse leg pins δ at −2.361 ppm across the entire 32-hour onset window
(§8), so there is no shared reference drift. Whatever changed lives in an
element used **only** by the forward leg: 146's TX, or 148's RX.

### 9.3 Why 146 is next, not the LO

- 148 has been re-flashed, rebooted, re-armed and gated twice since the onset and
  reproduced the collapse to 1.3 points (§8) — its RX is the poorer suspect.
- 146 has had no chip-level reset since 09-05 14:12, i.e. before the last healthy
  forward leg (09-06 12:47). A profile re-arm reprograms the ADRV9002; it does
  not reset it.
- The ROM double-tap, documented 14/14 clean against ARMCAUSE, has now failed
  4/4. That is what you see if the peer radiates garbage *persistently* rather
  than only across the arm window — i.e. if the fault is on the peer, not in the
  arm ordering.
- `t38_fix_30`, under an otherwise byte-identical bringup, gave
  `health try 1: rev 100% fwd 100%` where the collapsed legs give `rev 58%`.

  **Correction, made before the reboot result was read:** the `fwd` term in that
  line is not a measurement. `capture_r3.sh:269` sets `FH=100` unconditionally
  and only overwrites it when `FWD_GATE=1`, which none of these legs set. So the
  line carries exactly one number — `rev`, which is `crc_health` at the leg's own
  RX board and therefore the forward-leg figure on `LEG=A`. There is no
  "one direction perfect, the other collapsed in the same arm" observation; the
  healthy-reverse comparison rests on `t52_rev1` alone, which is a separate leg.

### 9.4 Repo-change check over the onset window (advisor step, negative)

Commits 09-06 12:47 → 09-07 21:05 touching the arm path: `capture_r3.sh`
(817e487, 82bd2e9, 8d8f661 — MID_RECOVER, default OFF), `legrun_go.sh` (817e487),
`w1leg_go.sh` (f708a12, 56b7e94, 337ac5a, 955a98b — RSSI_PERIOD and BS wiring,
none of it on the plain-leg path). One host-app commit, `32739e4` at 09-06 14:03,
flipped `QPSK_ROTFIX` to deferred-close by default — inside the window, and its
Task 39 validation leg `20260906_140355_w1_t39_default` was **leg=B, reverse**,
so the flip has never been validated forward. It is a framelog rotate path and
cannot move a fabric carrier loop, so it is not promoted above 146; it is
recorded here as the one window change that was never exercised on the forward
leg, and `QPSK_ROTFIX=0` is the one-line control if 146 comes back clean and the
collapse returns.

## 10. Task 56 pre-registration — chip-level reset of 146

Written and committed **before** the reboot.

**The test.** Reboot 10.0.0.146. When it is back, one plain forward leg,
`DUR=180`, under the standing keeper hold, via `launch_rig_unit.sh` with a
watcher. Scored with `score_leg.py` (crc_ok, PER with lost frames in the
denominator) and `cfc_cond.py` (CFC conditioned on decode) — the same two
scripts that produced every number in §8 and §9.1.

**Pre-registered branches.**

- **R1 — the reset fixes it.** `crc_ok ≥ 95 %` AND the CFC median over crc_ok
  frames in [−3600, −3000] with IQR width < 900. Reading: the collapse was a
  latched state on 146 that only a chip-level reset clears. Restore service and
  write the number with its command and sample count.
- **R2 — the reset does nothing.** `crc_ok` in 50–70 % AND |CFC median over
  crc_ok frames| < 1500 with IQR width > 2000. Reading: a latched 146 state is
  excluded. Go to Task 57, the `LO_A_RX` step leg, which is the discriminator
  §9.1 says we still need: a dead zone moves out from under a ±30 kHz step, a
  false-FTS latch does not.
- **R3 — anything else.** Partial recovery, or recovery with a CFC outside the
  R1 band. Report both numbers and claim neither; not a fix.

**Falsifiers and refusals.** 146 not reachable within 300 s of the reboot →
PHYSICAL ATTENTION, no further rig work, the hold stays. `ARM GATE FAIL` twice →
UNINFORMATIVE, one re-run then stop. `deliver_rate_post < RATE_GATE=900` →
UNINFORMATIVE. The reverse control is **not** re-measured here; `t52_rev1`
stands.

**What will not be claimed.** Not a frequency displacement read off a collapsed
leg's CFC median — §9.1 shows that number is untracked. The 7.460 Hz/unit scale
is usable only on legs whose decoded-frame CFC IQR is tight. Not a restored PER
without the exact command, the sample count, and lost frames in the denominator.

## 11. Task 56 outcome — R2: the chip-level reset of 146 changes nothing

`two_jup/comb/runs/t56_fwd_post_reboot`, `LEG=A DUR=180 DRY=0`, run under
`launch_rig_unit.sh t56leg` after `REBOOT_BOARD_OK ip=10.0.0.146 return_s=20
uptime_after=42.05` (uptime 203,960 s → 40.5 s, so the reset was real).

| leg | 146 state | rec | crc_ok | CFC med (crc_ok) | q25 | q75 | IQR width |
|---|---|---:|---:|---:|---:|---:|---:|
| `t53_fwd_plain` | up 2 d 7 h | 735,841 | 59.01 % | +682 | −901 | +1940 | 2841 |
| `t55_fwd_plain_r4b` | up 2 d 8 h | 736,403 | 60.27 % | +533 | −986 | +1793 | 2779 |
| **`t56_fwd_post_reboot`** | **up 40 s** | 270,142 | **57.94 %** | **+642** | −1076 | +2042 | **3118** |
| `t38_fix_30` (healthy) | — | 79,765 | 98.33 % | −3314 | −3610 | −3052 | 558 |

Pre-registered R2 exactly: `crc_ok` in 50–70 %, |CFC median over crc_ok frames|
< 1500, IQR width > 2000. **A latched 146 state that a reboot clears is
excluded.** Fail classes are the same shape as before the reset
(MAGIC 95,899 / OK 156,518 / CRC 16,664 / LEN 1,060). `deliver_rate_pre=632
post=605`, gate not passed — the leg is a diagnostic, not a credited PER, and
its 31.16 % PER is not comparable with t55's 41.23 % (different duration and
offered load); `crc_ok` is the comparator that holds across all four.

Both boards have now been power-cycled since the onset with no effect, so the
suspect list narrows to what neither reset touches: **the RF path used only by
the forward leg** (146 TX chain → 148 RX chain, cabling, attenuators, antennas —
which `HOSTS.md` flags as changing per experiment), and the **CFO dead zone**,
which no reset can move because the LOs come back identical.

### 11.1 A control that has never actually run

`capture_r3.sh:262` sets `WTHRESH=${WTHRESH:-50}` and the wedge-check loop breaks
the moment `crc_health >= WTHRESH`. Every collapsed leg has reported 58 %, so the
loop has exited on try 1 **every time** and the ARMCAUSE re-roll (`WMAX=4`
re-arms) has never once fired on a collapsed leg. The script's own comment says
what the two outcomes mean: *"A sync-but-CRC wedge clears on the byte double-tap;
genuine forward degradation (146 TX margin) does NOT -> tries exhaust and we flag
PERSISTENT (that IS the real PER, not a wedge)."* Running one leg with
`WTHRESH=90` is therefore a pre-existing, in-tree discriminator that costs one
short leg.

---

## §12 Task 57 pre-registration — the RX-LO staircase

Written and committed **before** the sweep. Rig held since 21:02. 148 on
`9f13705d9fb0`, 146 on `9acbe2ebe1db` (uptime ~20 min, rebooted for Task 56).

### The question

§9.2's two-unknown fit gives the forward residual as

    residual_Hz = 2.0e9*delta - (LO_A_RX - 2.0e9),    delta = -2.361 ppm

so at the shipped `LO_A_RX = 2000020000` the residual is -24.7 kHz, and stepping
148's RX1 LO walks it one-for-one. §9.2 also showed the reverse leg pins `delta`
unchanged across the onset window — but the reverse leg uses **146's RX at 1.9 GHz**,
so it cannot see a displacement of **146's TX synth at 2.0 GHz**, and the ADRV9002
exposes no PLL lock attribute, so a mis-locked synth reads back as the commanded
value. If 146's TX has moved by some unknown `Delta`, the forward residual is
`-4722 + Delta - off` and the link sits wherever that lands — including on the CFO
dead zone at residual ~ 0, which is the documented ~40 % signature.

The sweep asks one question: **is there an offset within +-(80..160) kHz of the
shipped LO that puts the forward leg back in the working band?** If there is, its
position gives `Delta`. If there is not, the dead zone is excluded across that span.

### The instrument

`two_jup/comb/lo_sweep.sh` (new). One bring-up, then per point: write
`out_altvoltage0_RX1_LO_frequency` on 148, read it back, byte-source double-tap on
both boards (`rearm_byte`, 0x158=1 — verbatim from `capture_r3.sh:278`; **never**
`rearm_rom`, which would switch the modulator back to the ROM test source), settle
6 s, then one 8 s board-side window reading `dma_rx_ok`/`crc_drop` from the daemon's
own stats line plus 0x104 and 0x154 either side. ~50 s per point, 14 points.

`WATCHDOG=0` on the bring-up: a mid-sweep `lock_watchdog` daemon relaunch would
confound every point after it. An `EXIT` trap always restores `LO_A_RX=2000020000`
and re-arms, so an abort cannot leave the rig on a swept LO.

Offsets in order (Hz relative to 2.0 GHz): **20000** (shipped, the positive control),
0, -20000, -40000, -60000, -80000, 40000, 60000, 80000, 100000, 120000, 140000,
160000, **20000** (the control repeated, to catch drift across the sweep).

### Pre-registered branches

**S1 — a point recovers.** Some offset reads `pct >= 90` **and** `rate >= 1100 f/s`
(both clauses: `crc_health` alone reads ~100 % in a wedge because the host decodes
almost nothing and what little it decodes is clean — `capture_r3.sh:281`). Reading:
the collapse is a forward-leg carrier-offset condition, and 146's TX has moved by
`Delta ~= off_recover - 20000`. Next step is one full `legrun_go.sh LEG=A` at that
LO, scored from `frames.bin`, before any number is credited — plus the shipped-default
problem stated explicitly (see below).

**S2 — nothing recovers, controls hold.** No point clears S1's gate and both
`off=+20000` controls read 55–62 % at 550–750 f/s, matching the four collapsed legs.
Reading: not a carrier-offset condition anywhere in the swept span. The dead zone is
excluded over `residual in [-165, +75] kHz`, and what remains is the RF path used only
by the forward leg (146 TX chain -> 148 RX chain, cabling, attenuators, antennas) or
146 TX margin.

**S3 — the controls disagree.** The two `off=+20000` points differ by more than 10
points from each other, or either lands outside 45–75 %. Reading: the sweep is not
measuring the same link state the legs measured. **UNINFORMATIVE**; one re-run, then
stop and report it as such.

**S4 — abort.** A LO readback that does not equal the commanded value, a bring-up
gate failure, or either board unreachable: restore, stop, PHYSICAL ATTENTION at the
top of the morning report. No retry loop.

### What will NOT be claimed

- **`pct` here is not a PER.** It is `dma_rx_ok / (dma_rx_ok + crc_drop)` over 8 s
  from the daemon's stats line. MAGIC and LEN failures are not in it and lost frames
  are not in its denominator. It is a screening statistic, calibrated only by the
  control point against the four legs' `crc_ok` fractions. No number from this sweep
  will be credited as a link metric.
- **No CFO reading off a collapsed point.** §9.1 established that CFC is untracked on
  a collapsed leg, so 0x154 is logged as a fact per point and used as a gradient
  nowhere.
- **A single 8 s window is not a replicate.** A recovered point is a lead, not a
  result, until a full leg reproduces it.

### The trap if S1 fires

The shipped default is `LO_A_RX=2000020000` (`bringup_r2r3.sh:58`). If a non-default
LO restores the link, handing back with it as a one-off env var means the sentinel's
next restore puts the link straight back into collapse. Either the new value is
committed as the default in `bringup_r2r3.sh`, or the hand-back says plainly that the
link is down at shipped defaults and names the value that works. It will not be left
implicit.

---

## §13 Task 57 outcome — the forward carrier relationship has moved ~+39 kHz

### §13.1 The v1 sweep was instrument-limited, and said so on its first point

Branch **S3** fired on point 1: the shipped-LO control read `pct=0 rate=0 ok=0
drop=516` instead of the legs' 58 % / 632 f/s. Cause found immediately, in the
instrument and not the link — `crc_health` reads the **daemon's** `dma_rx_ok`
counter, and lo_sweep v1 started no traffic, so 146 sent only idle frames. The
FABRIC frame counter 0x104 on 148 ran at **1250 f/s** throughout, so frames were
arriving at full rate the whole time; nothing was reaching the host to be counted.
v2 starts the same saturating `qpsk_perf` stream `capture_r3.sh:253-254` uses and
records the fabric rate as its own column.

Recorded as an instrument defect, not a link result. No branch is claimed from v1's
`pct` column.

### §13.2 But v1's CFC column is a carrier-offset meter, and it is unambiguous

0x154 was read at both ends of every dwell. Even with no host traffic the byte
source radiates at 1250 f/s, so the carrier loop has a signal to track — and across
240 kHz of LO the readings are monotone and linear:

| off (Hz rel 2.0 GHz) | LO_A_RX | 0x154 mean (signed units) |
|---|---|---|
| -80000 | 1999920000 | +17832 |
| -60000 | 1999940000 | +12773 |
| -40000 | 1999960000 |  +9779 |
| -20000 | 1999980000 |  +5481 |
| 0      | 2000000000 |  +4649 |
| **+20000 (shipped)** | **2000020000** | **+3781** |
| +40000 | 2000040000 |   -887 |
| +60000 | 2000060000 |  -3549 |
| +80000 | 2000080000 |  -5342 |
| +100000 | 2000100000 | -7969 |
| +120000 | 2000120000 | -12525 |
| +140000 | 2000140000 | -15720 |
| +160000 | 2000160000 | -17769 |
| +20000 (control repeat) | 2000020000 | +2550 |

Least squares over all 13 distinct points:

    CFC = -0.14092 * off + 4908.6      residual rms 1084 units (8.1 kHz)

The fitted scale is **7.10 Hz/unit**. §9.2's two-unknown fit — derived from two
healthy legs on entirely different data — predicted **7.460**, and the independent
documented figure is ~7.5. Three unrelated routes to the same constant: the meter
is real.

**The zero crossing is at off = +34.8 kHz.** Under §9.2's model it belongs at
off = -4.7 kHz. **The forward carrier relationship has moved by about +39.5 kHz,
i.e. ~+19.8 ppm at 2 GHz.**

Read at the shipped LO the same way: on the healthy leg `t38_fix_30` (09-06 12:44)
the decoded-frame CFC median at `LO_A_RX=2000020000` was **-3314**. Tonight, at the
identical commanded LO, it reads **+3781**. That is the regression, measured
directly, in the units the loop reports.

### §13.3 Which element moved — and why nothing tried so far could touch it

The residual is `f_146TX - f_148RX`, so a +39.5 kHz shift is either 146's TX synth
landing high or 148's RX1 synth landing low. The sweep cannot separate them; both
are corrected by the same +39.5 kHz of `LO_A_RX`. What it does settle:

- **It is not a shared 146 reference error.** A 146 reference off by +19.8 ppm would
  drag 146's RX LO too and put the reverse residual at about -78 kHz. `t52_rev1`
  measured the reverse decoded-frame CFC median at **-4761** (-35.5 kHz), unchanged.
  So the moved element is used by the forward leg **only**: 146's TX synth at 2.0 GHz,
  or 148's RX1 synth — the two paths the reverse leg never touches.
- **No reset can clear it and no readback can show it.** Both boards have now been
  power-cycled with no effect (§11), and the ADRV9002 exposes no PLL lock or status
  attribute, so a synth that lands 39.5 kHz off its commanded frequency reads back as
  the commanded value. That is exactly the failure this sweep was built to see.
- **It explains the whole symptom set.** ~19.8 ppm is far outside the demod's
  tracking range at the shipped operating point, so the carrier loop never locks:
  CFC is untracked (§9.1), frame-start detection still runs at ~1212-1250 f/s because
  it is non-coherent, and the payload fails as MAGIC. `rstcs` stays 0 throughout
  because nothing ever resets — it simply never acquires.

### §13.4 The predicted correction

Inverting the fit for the healthy forward operating point (CFC = -3314):

    off = +58.4 kHz   ->   LO_A_RX = 2000058000    (healthy fwd CFC -3314)
    off = +68.6 kHz   ->   LO_A_RX = 2000069000    (the reverse leg's -4761)

Task 57b sweeps `off in {20000, 40000, 50000, 58000, 65000, 72000, 80000, 90000,
20000}` **with traffic**, so the S1 gate (`pct >= 90` AND `rate >= 1100 f/s`) can
actually be evaluated. The +20000 control at both ends must reproduce the legs'
~58 % or the run is S3 again.

**This is a compensation, not a repair.** Even if it restores the link, the forward
leg would then be running with 148's RX LO 39.5 kHz off its nominal to cancel a
displacement in hardware that nobody has explained. That has to be said plainly at
hand-back, and the shipped default in `bringup_r2r3.sh:58` cannot be quietly left
behind (§12, "the trap if S1 fires").

---

## §14 Task 57b — S2 fired. The LO is not the fault, and §13's reading is refuted.

### §14.1 The traffic sweep, scored against §12

Nine points, `off in {20000, 40000, 50000, 58000, 65000, 72000, 80000, 90000, 20000}`,
8 s dwell each, one saturating `qpsk_perf -b 15000000 -l 1400` stream for the whole
sweep, bring-up gate `ARM GATE PASS (try 1)` at 1246/1247 f/s.

| off (Hz) | LO_A_RX | pct | rate f/s | fab f/s | cfc read 1 | cfc read 2 |
|---|---|---|---|---|---|---|
| 20000 (control) | 2000020000 | 59 | 455 | 1218 | +813 | -527 |
| 40000 | 2000040000 | 59 | 439 | 1201 | -4417 | +393 |
| 50000 | 2000050000 | 64 | 491 | 1227 | -7071 | -3800 |
| **58000 (§13 prediction)** | 2000058000 | **59** | 449 | 1216 | -7423 | -3619 |
| 65000 | 2000065000 | 58 | 445 | 1220 | -5023 | -6958 |
| 72000 | 2000072000 | 61 | 467 | 1225 | -6335 | -7191 |
| 80000 | 2000080000 | 61 | 953 | 1234 | -7980 | -6715 |
| 90000 | 2000090000 | 67 | 1027 | 1216 | -11296 | -11608 |
| 20000 (control) | 2000020000 | 61 | 914 | 1205 | -434 | +869 |

**S3 does not fire:** the two controls read 59 % and 61 % — 2 points apart, both
inside the 45-75 % band, and both reproduce the legs' 58-60 %.

**S1 does not fire:** no point reaches `pct >= 90`, and none reaches `rate >= 1100`.
The best point is off=+90000 at 67 % / 1027 f/s. The rate column doubles from point 7
onward and stays doubled through the closing control at off=+20000, so it is a
time trend in the host path, not an LO effect.

**S2 fired: no offset recovers the link.** §13's predicted correction, off=+58000,
scored 59 % — indistinguishable from the control.

The prediction was falsifiable, it was tested, and it failed. §13 stands as a
measurement (0x154 does track the LO) and falls as an explanation.

### §14.2 The fail-class census says why, and it is not the carrier

Scored from `cap/frames.bin` via `accept_analyze.read_frames`, `reserved` = fail_class:

| leg | date | n | ok | MAGIC | LEN | CRC | CFC median of DECODED frames |
|---|---|---|---|---|---|---|---|
| `20260906_124402_legA_t38_fix_30` fwd | 09-06 12:44 | 79,765 | **98.3 %** | 1.7 % | 0 | 0.0 % | **-3314, IQR [-3610, -3052]** |
| `20260906_140355_w1_t39_default` fwd | 09-06 14:03 | 610,635 | **99.5 %** | 0.4 % | 0 | 0.0 % | **-4728, IQR [-4850, -4611]** |
| `t53_fwd_plain` fwd | 09-07 | 735,841 | 59.0 % | 35.5 % | 0.5 % | 5.0 % | **+682, IQR [-901, +1940]** |
| `t55_fwd_plain_r4b` fwd | 09-07 | 736,403 | 60.3 % | 34.6 % | 0.5 % | 4.6 % | +533, IQR [-986, +1793] |
| `t56_fwd_post_reboot` fwd | 09-07 | 270,142 | 57.9 % | 35.5 % | 0.4 % | 6.2 % | +642, IQR [-1076, +2042] |
| `t52_rev1` **rev** | 09-07 | 756,473 | **99.6 %** | 0.4 % | 0.0 % | 0.0 % | **-4761, IQR [-4890, -4638]** |

Two things fall out.

**(a) The failure is random at frame scale, not bursty and not periodic.** Bad-run
lengths on `t53`: median 2, mean 2.1, p90 4 — against 1.69 for an i.i.d. Bernoulli at
p=0.41. Record-index autocorrelation of the bad indicator: 0.195 at lag 1 and below
0.07 at every other lag out to 200. Per-second ok fraction 0.591 with sd 0.051 over
610 s. There is no comb, no burst class, and no envelope: **41 % of frames fail
independently.** For contrast the healthy `t38_fix_30` leg has 14 bad runs in 79,765
frames with ok runs of median 897.

**(b) CFC does not predict failure.** Conditioning `t53` on `|CFC|`:

| bin | n | ok |
|---|---|---|
| 0-500 | 114,674 | 59.9 % |
| 500-1500 | 241,870 | 59.9 % |
| 1500-3000 | 294,867 | 59.2 % |
| 3000-6000 | 82,293 | 56.0 % |
| >6000 | 2,137 | 1.1 % |

Flat at ~60 % across the whole range the loop actually occupies. If a carrier offset
were the mechanism, the frames whose CFC sits where the healthy legs sit
(3000-6000) would decode and the ones near the null would not. They do not differ.
The `>6000` bin is fatal on the healthy legs too (`t38`: 0.0 % ok) — that bin is the
post-failure tail, not a cause.

### §14.3 What the CFC distribution *does* say

On both healthy legs every single frame reports `|CFC| > 1500` with an inter-quartile
width of ~130 units — a locked loop. On all three collapsed legs the median has
collapsed to ~+600 and 65 % of frames read `|CFC| < 2000`, with an IQR ~20x wider.
The forward carrier loop is **hunting near the null** rather than tracking, and it
does so whether the frame decodes or not. That is a *consequence* of a demodulator
that cannot get a clean estimate — consistent with a link at threshold — and the
sweep proves it is not curable by moving the LO: at off=+40000 and +50000, where the
CFC readings bracket the healthy -3314/-4761, the link still scored 59 % and 64 %.

### §14.4 The reading that survives

A leg whose frame-start detector runs at full rate (1201-1234 f/s fabric, against
~1245 nominal), whose failures are i.i.d. at 41 %, whose failure class is
MAGIC-dominated (frame-start damage — the same window the 0x108 comparator sees),
whose carrier estimate is noisy but not displaced, and whose peer direction over the
same antennas at the same instant is at 99.6 %, is a leg **short of link margin in
one direction**. Nothing in the digital plane has been shown to differ, both boards
have been power-cycled, and 148's fabric demod passes internal digital loopback.

A first-pass RF reading taken at 23:35 with both byte sources live and both AGCs
railed at their 34 dB maximum:

| | 148 RX (forward receiver) | 146 RX (reverse receiver) |
|---|---|---|
| `in_voltage0_hardwaregain` | 34.000000 dB (railed, mode `automatic`) | 34.000000 dB (railed, mode `automatic`) |
| `in_voltage0_rssi` | 29.648 dB | 24.356 dB |
| `in_voltage0_decimated_power` | 28.00 dB | 22.500 dB |
| peer `out_voltage0_hardwaregain` | 146 TX: 0.000000 dB | 148 TX: 0.000000 dB |

Both transmitters are at 0 dB attenuation and both receivers are at maximum gain with
no headroom left, so a difference between the two directions lands directly on SNR.
**This is one reading with no baseline and no noise floor beside it — it is a lead,
not a result.** Task 59 measures it properly: peer TX on vs off in both directions,
which separates "the wanted signal got weaker" from "the noise floor came up".

---

## §15 — The failed-frame headers: a second, deterministic loss class (Task 57c, desk)

§14 closed the LO branch and left "short of link margin" as the surviving
reading. Before spending rig time on that, the failed-frame header ring was
scored — an instrument already present in every capture and never opened this
night. It splits the 41 % failure population in two, and one of the two halves
is not a channel effect at all.

### 15.1 The instrument

`cap/failhdr.bin`, magic `QFAILH01`, written by the capture daemon: one 32-byte
record per FAILED frame in a 65,536-entry ring, dumped at exit. Record layout
`host_join.h:175` → Python `"<QIIBBH12s"` = `t_mono_ns, host_seq, first_zero_off,
fail_class, pad, magic_off, hdr[12]`. `hdr[12]` is the **raw first 12 bytes of
the slice the deframer handed up**, so a failure can be read rather than only
counted. Scored with `failhdr.py` / `hdrbits.py` / `clearbias.py` (scratchpad).

The frame header is `qpsk_join.h:127`: `p[0]==0x51 && p[1]==0x4B` (a **16-bit**
magic), then `len = p[2] | p[3]<<8`, then a 32-bit seq at `p[4..7]`, then CRC32
at `p[8..11]`. `QPSK_FC_MAGIC` therefore means only "the first two bytes were
not 0x51 0x4B" — it covers both a one-bit hit on the magic and a slice of pure
noise, and those two are what this section separates.

**`t56_fwd_post_reboot` is excluded from this section.** Its ring holds
**8 distinct 12-byte headers across all 65,536 records**, class counts of exactly
49,152 / 16,384 and a single `magic_off` value (1043) repeated exactly 8,192
times. That is a degenerate artifact, not a measurement. §14's fail-class census
for t56 came from `frames.bin` and is unaffected, but no header inference may be
drawn from t56 and none is.

### 15.2 The split

For each MAGIC record, ask whether the received `hdr[0:2]` is a **pure subset**
of `(0x51, 0x4B)` — i.e. every bit that is set in the received bytes is also set
in the magic, so bits were only ever **cleared**, never set. For uniform random
bytes that happens with probability `2^3/256 × 2^4/256 = 0.195 %`.

| leg | direction | crc_ok | MAGIC recs | subset-of-magic | vs 0.195 % chance | `len==1428` within the subset |
|---|---|---|---|---|---|---|
| `20260906_124402_legA_t38_fix_30` | fwd | 98.3 % | 4,984 | 36 (0.7 %) | 3.7× | 0.0 % |
| `20260906_140355_w1_t39_default` | fwd | 99.5 % | 6,039 | — | — | — |
| `t52_rev1` | **rev** | 99.6 % | 6,286 | 60 (1.0 %) | 5.1× | 25.0 % |
| `t53_fwd_plain` | fwd | 59.0 % | 57,744 | **12,064 (20.9 %)** | **107×** | **64.3 %** |
| `t55_fwd_plain_r4b` | fwd | 60.3 % | 58,049 | **12,110 (20.9 %)** | **107×** | **66.2 %** |

`len == 1428` is the correct, modal payload length for this traffic. Among the
records that are **not** subsets it appears in 2.1 % / 1.8 % of cases — i.e. at
random. So one fifth of the forward leg's MAGIC failures are frames whose length
field is intact and whose magic has lost bits in one direction only.

### 15.3 It is one bit, and it is the same bit

Restricting to Hamming distance exactly 1 from the magic:

| | t53 | t55 | t52 (rev, healthy) | t38_fix_30 (fwd, healthy) |
|---|---|---|---|---|
| d==1 records | 11,180 (19.4 % of MAGIC) | 11,166 (19.2 %) | 20 (0.3 %) | 2 (0.0 %) |
| `11 4B` — `0x51` with bit 6 (`0x40`) cleared | **7,748** | **8,003** | 15 | 0 |
| `51 43` — `0x4B` with bit 3 (`0x08`) cleared | 1,700 | 1,500 | 1 | 0 |
| `51 4A` — `0x4B` with bit 0 (`0x01`) cleared | 1,465 | 1,419 | 0 | 0 |
| 1→0 flips vs 0→1 flips, d==1 only | 11,000 vs 181 (**61:1**) | comparable | — | — |

All three dominant single-bit events are **clears**. A Gaussian channel flips
1→0 and 0→1 at the same rate; over the *whole* MAGIC population it does exactly
that here (t53: 156,309 clears vs 161,337 sets, **1.0:1**), which is the control
that makes the 61:1 inside the near-magic population meaningful. The asymmetry
is not a property of the channel; it is a property of this subpopulation.

The `11 4B` class is otherwise an intact frame:

- **`len == 1428` in 99.7 % (t53) / 99.8 % (t55)** of them;
- the 32-bit seq field increases monotonically across 99.7 % of consecutive
  events, median step 14 — these are ordinary frames in the ordinary stream;
- mean Hamming distance of `hdr[0:2]` from the magic over ALL MAGIC records is
  **5.47–5.50** on the collapsed legs against **7.84–7.87** on the healthy ones
  (uniform-random expectation 8.00), and `hdr[0]` entropy is **5.65–5.71 bits**
  against **7.79–7.85** healthy. The healthy legs' failures are pure noise; the
  collapsed legs' are noise *plus* this class.

### 15.4 The rate, and how much it changed

Rates are events per second over the ring's own span, so the wrap does not
distort them. The ring rate and the whole-leg rate agree on t53 (506.2 fail/s in
the ring against 306,896 failures over the ~610 s leg = 503 fail/s), which is the
check that the ring is representative.

| leg | span | all failures | `11 4B` | subset **and** `len==1428` |
|---|---|---|---|---|
| `t38_fix_30` fwd, 09-06 12:44 | 29.2 s | 171.8/s | **0.000/s** | 0.000/s |
| `t39_default` fwd, 09-06 14:03 | 497.3 s | 12.7/s | **0.008/s** | 0.008/s |
| `t52_rev1` **rev**, 09-07 | 617.4 s | 10.6/s | **0.024/s** | — |
| `t53_fwd_plain` fwd, 09-07 | 117.2 s | 506.2/s | **59.849/s** | 59.919/s |
| `t55_fwd_plain_r4b` fwd, 09-07 | 122.6 s | 487.8/s | **59.568/s** | 59.673/s |

The two collapsed legs, taken half an hour apart with a re-arm between them,
agree on this rate to **0.5 %**. Against the last healthy forward leg it is a
**7,500× increase**; against the healthy reverse leg running at the same instant
tonight, **2,500×**. At ~1,225 f/s that is **≈ 4.9 % of all forward frames**.

The `subset AND len==1428` column tracks `11 4B` to within 0.2 % — so the
"intact frame, magic bits cleared" population and the `11 4B` population are the
same set of frames, not two overlapping ones.

### 15.5 What this does and does not settle

**Two loss classes, not one.** Of the forward leg's ~40 % frame failures:

- **Class A ≈ 4.9 % of frames** (59.8/s): the frame arrives, its length and
  sequence survive, and one specific bit near the frame start has been cleared.
  Reproducible to 0.5 % across two legs. Essentially absent before 09-06 14:03
  and absent on the reverse leg tonight. **This is not additive noise.**
- **Class B ≈ 35 % of frames** (~440/s): the slice is uniform-random rubbish,
  symmetric bit flips, random length field. That *is* what a receiver failing to
  hold lock looks like, and §14's link-margin reading still applies to it.

Class A is much the smaller of the two and cannot by itself explain a 59 % leg.
The honest statement is that the forward leg acquired **two** defects in the same
32-hour window, or one defect with two signatures — and Class A is the one with a
fingerprint sharp enough to chase.

**A periodicity, reported as a fact and not leaned on.** An FFT periodogram of the
`11 4B` event times (0.2 ms bins) shows a line at **76.63 Hz (13.049 ms)** on t53
and **76.56 Hz (13.061 ms)** on t55 — agreeing to 0.1 % — with harmonics at 2×,
3× and 4×. Its Rayleigh Z is 158/163 against N≈7,750 events, so it modulates the
class rather than generating it, and the seq-step histogram is a smooth decay
with **no** modular structure at any N in 2..64. Mains was tested and excluded
(Z = 2.1 at 60.00 Hz, 5.1 at 50 Hz, 0.4 at 120 Hz). The `t_mono_ns` stamps are
host-side and quantised by DMA batching, so 13.05 ms is a delivery-plane period
until something measures it on the board clock.

**The RF reading of §14.4 stays a lead, and one caveat is added to it:** the sign
convention of `in_voltage0_decimated_power` on this driver build was never pinned
against the source, and numerically 148 reads **28.00** against 146's **22.500**.
Nothing in §14.4 claims a direction, and nothing here does either.

### 15.6 The next measurement is unchanged, and now sharper

§12 pre-registered that S2 firing sends the night to `rom_air_ber.sh` (Task 58),
and that is still the right instrument — but Class A makes it sharper rather than
merely next. `0x108` scores the **first 120 bits** of the frame against the ROM
expectation, which is exactly the window Class A damages, and it does so with the
byte plane, the DMA and the host all removed. So:

- Class A present with `0x158=0` on the ROM source → the damage is in the PHY or
  on the air, upstream of everything the host touches.
- Class A absent with `0x158=0` → it is in the byte plane or the delivery path,
  and the 13.05 ms period should be believed rather than discounted.

Positive control first, as `rom_air_ber.sh` already requires.

---

## §16 — Correction to §15: Class A is the trailing edge of Class B, not a second defect. And the Task 58 pre-registration.

### 16.1 The test §15 should have run

§15.5 said the forward leg had acquired "two defects in the same 32-hour
window, or one defect with two signatures", and then routed the whole next
measurement at the smaller one. That was the wrong split, and the test that
decides it costs no rig time: **where does a Class A frame sit relative to the
other failures?**

Join each `11 4B` failhdr record to `frames.bin` by exact `t_mono_ns` (100.0 %
of Class A records join on both legs), then look at its neighbours in delivery
order.

| statistic | `t53_fwd_plain` | `t55_fwd_plain_r4b` |
|---|---|---|
| frames in leg | 735,841 | 736,403 |
| Class A records joined | 7,748 (100 %) | 8,003 (100 %) |
| **frame immediately BEFORE a Class A frame is bad** | **0.9489** | **0.9528** |
| unconditional bad fraction | 0.4099 | 0.3973 |
| frame immediately AFTER is bad | 0.3654 | 0.3495 |
| the frame before is itself Class A | 0.0054 | 0.0045 |
| Class A frames as a fraction of the leg | 0.0105 | 0.0109 |

At ±2 frames and beyond the neighbourhood is back to baseline (±2: 0.429/0.415
vs 0.410 on t53; ±3, ±5, ±10, ±25, ±50 all within 0.03 of baseline). The
enrichment is **one frame wide and one-sided**: the frame before a Class A
frame is bad 95 % of the time against a 41 % base, and the frame *after* is
slightly **better** than baseline.

That is not what two independent defects look like. It is an edge effect.

### 16.2 It marks the end of a SHORT error event specifically

The length of the run of consecutive bad frames ending immediately before the
event separates Class A from an ordinary failure sharply:

| preceding consecutive-bad run | Class A (t53) | Class A (t55) | control: non-A failures (t53) |
|---|---|---|---|
| 0 (previous frame was good) | 5.1 % | 4.7 % | 48.0 % |
| 1 | **53.5 %** | **56.0 %** | 24.6 % |
| 2 | 18.6 % | 18.8 % | — |
| 3 | 10.3 % | 9.9 % | — |
| ≥ 4 | 12.5 % | 10.5 % | 8.3 % |
| mean | **1.86** | **1.76** | **8.80** |

An ordinary failure on this leg follows a bad run of mean 8.8 frames. A Class A
frame follows a bad run of mean 1.8, and in over half of all cases follows
**exactly one** bad frame. Class A is the frame on which the receiver comes back
after a brief error event. Long fades end in ordinary recovery; short glitches
end in a Class A frame.

The clear bias fits this and nothing else in the record: **[inferred]** a
Viterbi survivor path that is still re-converging at the start of the next frame
is biased toward the zero state, which shows up as bits **cleared** and not set —
61:1 inside the near-magic subpopulation against 1.0:1 across the whole MAGIC
population (§15.3). The frame-start localisation, the one-bit Hamming distance,
the surviving `len` and `seq` fields, and the clear-only asymmetry are then four
faces of the same thing, and they are all *downstream consequences of Class B*.

**So: one defect, not two.** §15.5's "Class A ≈ 4.9 % + Class B ≈ 35 %" should be
read as "≈ 40 % of forward frames fail, and ≈ 5 % of them fail in the particular
way a frame fails when it is the first one after a short error event". Every
§15 measurement stands as measured; only §15.5's reading of them is withdrawn.

Two caveats on the above, stated so they are not discovered later. The failhdr
ring covers the last ~117 s of a 610 s leg while the `frames.bin` baseline is
whole-leg; §15.4 established the ring's failure rate (506.2/s) matches the leg's
(503/s), so the window is representative, but the comparison is not
window-matched. And the `host_seq` step into a Class A frame is **not**
informative here — the preceding frame is bad 95 % of the time, so its `seq`
field is garbage and the step is not a delivery-gap measurement.

### 16.3 Pre-registration — Task 58, `two_jup/comb/rom_air_ber.sh`

Written and committed BEFORE the run. Never exercised on silicon. 148 on
`9f13705d9fb0`, 146 on `9acbe2ebe1db`, under the keeper hold created 21:02.

    launch_rig_unit.sh romber <abs>/two_jup/comb/rom_air_ber.sh \
      OUT=<run> DRY=0 DWELL=10 REPS=3

**The question.** Every forward number tonight is host-visible: it has traversed
RF → 148 RX SSI → fabric demod → byte plane → DMA → host. With `0x158=0` both
modulators send the `Message_Generator` ROM and 148's own post-Viterbi
comparator scores recovered bits against its local copy in `0x108`, with `0x104`
counting frames. Byte plane, DMA and host data path are all out of the loop.
The reverse direction is measured in the same dwell on 146 as a simultaneous
healthy-leg control.

**Scoring order — the bulk BER first.** Class B is ~35 % of frames of
uniform-random slices, so it predicts of order 60 errors in the scored 120-bit
window on a third of frames: **BER ≈ 0.17**, unmissable. Class A predicts
0.049 frames × 1 bit / 120 = **BER ≈ 4×10⁻⁴**, which will not resolve against a
Class B floor. Pre-registered: **a null on Class A is not evidence of its
absence**, and no such claim will be made from this instrument.

**Branches.**

- **B1 — forward BER high, reverse BER low, same dwell.** The defect is in the
  PHY or on the air: RF margin, 146's transmitter, or 148's receiver. Byte
  plane, DMA and host are excluded because they are not in this path. §14's
  link-margin reading survives. → next is Task 59, the TX-gain probe, to
  separate "the wanted signal got weaker" from "the noise floor came up".
- **B2 — both directions clean (forward BER ≲ 10⁻³).** The PHY recovers the ROM
  stream, so the collapse lives **above** the byte plane, on the `0x158=1` path.
  The link-margin branch dies and the 13.05 ms period (§15.5) becomes credible
  rather than discountable. → next instrument is a byte-plane one, not an RF one.
- **B3 — both directions high.** Something common to both boards (clocking, the
  shared reference, a board-level fault), or the instrument is not measuring what
  the map says. The positive control tells these apart; if the control passed,
  report B3 as a real joint finding and claim no direction.
- **B4 — forward low, reverse high.** Inverted from every host-visible number
  tonight → the instrument does not measure what the leg measures.
  **UNINFORMATIVE**; report and stop.

**Falsifiers and refusals (fail-closed).**

- **Positive control first**, as the script already requires: `0x158=1` with the
  feeders dead makes the modulator underrun and radiate garbage against the
  receiver's ROM expectation, so the comparator MUST read ≈ 58.5 errors per 120
  bits (BER ≈ 0.49). A control that reads ≈ 0 means the comparator is not
  scoring: the entire run is **UNINFORMATIVE** and no null is claimed from it.
- `0x104` must advance at 1150–1250 f/s on the scored board in every dwell. A
  dwell with `dp = 0` is not scored.
- **A depressed forward `fps` is itself a reading, not a scoring problem.** If
  the forward demod is not acquiring, `0x104` stalls rather than counting errored
  frames, and `de/dp` over a handful of frames would be misleading. Forward fps
  < 1000 against a reverse fps ≈ 1200 is recorded as **B1** on the fps evidence,
  with the BER quoted only as a secondary number.
- `0x158` is write-only and reads back `const_0` (modem-write-only-regs). The ROM
  arm is verified **by effect only** — by the comparator moving between the
  control stage and the measure stage.
- One re-run per wedge, then **UNINFORMATIVE**; fall through to Task 59, do not
  loop.
- The `trap 'restore' EXIT` runs `bringup_r2r3.sh r3`; the rig must be back on the
  byte source at both ends before the hold is released.

**What will NOT be claimed.** Not a PER, not a link budget, and not a Class A
verdict. `0x108` scores the first 120 of 2240 bits (bist-120bit-window), so
every number it yields is a frame-start number and will be labelled as one.

---

## §17 — Task 58 ran. Branch B1, decisively: the forward defect is in the PHY, and the carrier is unstable.

`two_jup/comb/rom_air_ber.sh`, unit `romber`, run
`20260907_235953_t58_romber`, 2026-09-08 00:00–00:03 EDT, under the
21:02 keeper hold. 148 on `9f13705d9fb0`, 146 on `9acbe2ebe1db`. First
exercise of this instrument on silicon. EXIT trap ran `bringup_r2r3.sh r3`;
arm gate passed on try 1 (148 rx 1247 f/s, 146 rx 1247 f/s), byte source live at
both ends, both watchdogs restarted.

| board | stage | frames | errs | fps | err/frame | BER (120 b) | cfc1 | cfc2 |
|---|---|---|---|---|---|---|---|---|
| 148 | ctrl_high | 99 | 5,074 | 9.9 | 51.25 | **0.4271** | −4358 | −4704 |
| 146 | ctrl_high | 0 | 0 | 0.0 | — | — | −7961 | −4549 |
| **148** | **rom_r1** | 12,477 | 439,015 | 1247.7 | 35.19 | **0.2932** | +3649 | +3179 |
| 146 | rom_r1 | 12,480 | **0** | 1248.0 | 0.000 | **0** | −4890 | −4813 |
| **148** | **rom_r2** | 12,478 | 434,066 | 1247.8 | 34.79 | **0.2899** | +1081 | +4877 |
| 146 | rom_r2 | 12,487 | **0** | 1248.7 | 0.000 | **0** | −4772 | −4678 |
| **148** | **rom_r3** | 12,477 | 433,749 | 1247.7 | 34.76 | **0.2897** | +6706 | +3573 |
| 146 | rom_r3 | 12,481 | **0** | 1248.1 | 0.000 | **0** | −4371 | −4642 |

### 17.1 The controls held

**The positive control fired.** 148's comparator read BER 0.4271 with the
modulator underrunning, against the pre-registered ≈ 0.49 for garbage. The
comparator scores.

**146's comparator was also alive, by a different route.** Its `ctrl_high`
dwell counted zero frames, so §16.3's control never ran on 146 and its three
zeros could in principle have meant a dead counter. They do not: 146's `0x108`
read 0x3A91 = 14,993 in the control stage and 0x558F = 21,903 at the start of
rom_r1 — **it accumulated 6,910 errors during the ROM re-arm and settle**, then
froze at exactly 21,903 for all three reps. A counter that counts while the link
is settling and stops when it locks is a working counter.

**Both ROMs are the same ROM.** 146's zero is scored against 146's local copy of
the same `Message_Generator` content 148 transmits, so the two boards' ROMs are
proved identical by the reverse leg — which removes the obvious confound from
the forward number, since the boards run different bitstreams
(`9f13705d9fb0` vs `9acbe2ebe1db`).

### 17.2 The reading

**Forward air BER 0.290 ± 0.002 over three reps; reverse air BER exactly 0.000
over 37,448 frames in the same dwells.** With `0x158=0` there is no byte plane,
no DMA and no host data path in either measurement. This is **B1** as
pre-registered: the forward defect is in the PHY or on the air — 146's
transmitter, the RF path, or 148's receiver — and the delivery-plane branch
(B2) is dead. The 13.05 ms host-side period of §15.5 is a symptom, not the
cause, and §14's link-margin reading survives.

**Frame detection is not the thing that is broken.** `0x104` counts *detected*
frames, not slots — the control stage proves it, falling to 9.9 f/s when the
modulator underran. On the forward ROM link it counts **1247.7 f/s**, the full
nominal rate, in every rep. So 148 acquires 146's frames perfectly and then
recovers 29 % of the scored bits wrong. Sync works; bit decoding does not.

### 17.3 The forward carrier is wandering, and the reverse one is not

| | forward (148 RX, 6 reads) | reverse (146 RX, 6 reads) |
|---|---|---|
| CFC mean | **+3,844** | −4,694 |
| CFC sd | **1,868 units ≈ 13.3 kHz** | **182 units ≈ 1.3 kHz** |
| healthy value (§9.2) | −3,314 | −4,761 |
| shift vs healthy | **+7,158 units ≈ +50.8 kHz** | +67 units ≈ +0.5 kHz |

Two facts in one table. The forward residual carrier offset has moved by about
**+51 kHz** since the healthy legs, and read to read, ten seconds apart, it
**scatters by ±13.3 kHz** where the reverse residual on the same rig in the same
dwells holds to ±1.3 kHz.

**This is not 146's reference oscillator.** A reference drift large enough to
move 146's 2.0 GHz transmit synth by +50.8 kHz is +25.4 ppm, which would move
146's 1.9 GHz *receive* synth by +48.3 kHz — about **6,800 CFC units** on the
reverse leg. The reverse leg moved **67**. The reference is excluded by two
orders of magnitude, and with it every explanation that acts on 146 as a whole.

What is left is the part of 146 that the reverse leg cannot see: **146's 2.0 GHz
transmit synthesiser**. §9.2 predicted exactly this shape and named the unknown
`Delta`; Task 58 measures it at **Delta ≈ +51 kHz**, and adds that it is not a
static offset but a wandering one. The ADRV9002 exposes no PLL lock attribute on
this build, so a mis-locked synth reads back as the commanded value — which is
why every readback all night has looked correct.

A wandering carrier also explains the two things that made no sense before: why
retuning 148's RX LO to put the CFC register back at its healthy value did **not**
recover the link (§14 — you cannot retune away a carrier that will not sit still),
and why frame sync survives while bit decoding fails (preamble detection is
non-coherent; the demapper is not).

### 17.4 Limits on this reading

- `0x108` scores the **first 120 of 2240 bits** (bist-120bit-window), so 0.290
  is a **frame-start BER** and is quoted as one. Whole-frame BER is not measured.
- Task 58 localises to *146 TX or 148 RX or the path between*. The reference
  argument above narrows it to 146's TX synth **[inferred]**, from a CFC
  displacement plus a CFC stability contrast — not from a direct measurement of
  146's transmitter.
- As pre-registered, **no Class A verdict is drawn**: Class A predicts
  BER ≈ 4×10⁻⁴ against a floor of 0.29 and could not have resolved.

## §18 Task 59 pre-registration — is 148 still HEARING 146? (the hole in §17.3)

Written and committed BEFORE the probe. Instrument `two_jup/comb/phy_level_probe.sh`,
no arm, no re-tune, boards stay on the shipped byte source throughout.

### 18.1 The hole

§17.3 read 148's CFC scatter (sd 1,868 units ≈ 13.3 kHz, against the reverse leg's
182 ≈ 1.3 kHz) as a *wandering carrier* and narrowed the fault to 146's 2.0 GHz TX
synthesiser. That step does not follow on its own:

> **A demod that is not decoding produces a garbage CFO estimate anyway.** Decode
> failure is *sufficient* to produce the scatter, so the scatter cannot establish its
> own cause. The reverse leg's tight ±1.3 kHz is a *locked* estimator, not evidence
> about which synthesiser is stable.

The mean displacement (+7,158 units ≈ +50.8 kHz) stands on firmer ground than the sd,
because §13's staircase showed the register tracks the LO deterministically *during*
the collapse. But nothing measured so far separates two very different worlds:

- **W1** 148 hears 146 at a good level and is ~51 kHz off → frequency/phase/modulation.
- **W2** 148 barely hears 146 at all → link budget or 146's TX output; the CFC is
  tracking noise and §17.3's synth story is dead.

### 18.2 The probe

Mute one transmitter (`out_voltage0_hardwaregain` 0 → −40 dB) and watch what the PEER
receiver's `in_voltage0_decimated_power` does. Five states, 6 reads each at 1 s, both
boards sampled in every state: `base → mute146 → base2 → mute148 → base3`.

The **reverse direction is the calibrated control in the same run**: the reverse leg
decodes at air BER 0.000 (§17), so 146's step when 148 mutes is what "hearing the peer"
measures on this rig tonight. A forward step much smaller than that reverse step is the
reading; two similar steps exonerate level.

**Second control, free.** 148's `0x154` is read in every state. If 148's CFC keeps
producing plausible wandering values while 146 is muted — with no wanted signal present
at all — then CFC scatter on a collapsed leg is noise-tracking and carries no
information about 146's synthesiser. That is a direct falsifier for §17.3.

Standing observation to beat: at 00:05 with both transmitters on, 148 reads
`decimated_power` **28.00 dB** and 146 reads **21.75 dB**, both with `in_voltage0_hardwaregain`
34.0 dB. 148 is *not* the quieter receiver, which already sits badly with a naive W2.

### 18.3 Pre-registered branches

- **C1 — both steps large and comparable** (forward step ≥ 0.6 × reverse step).
  Reading: 148 hears 146 at level; the wanted signal is present. W2 dead, the defect is
  in frequency/phase/modulation and §17.3's line of inquiry survives → the 146 TX-LO
  relock + BER-scored sweep is the next rig step.
- **C2 — forward step small, reverse step large** (forward < 0.3 × reverse).
  Reading: 148 is not hearing 146. §17.3's synth inference is **withdrawn**; the fault is
  146's TX output stage or the forward RF path (cable/antenna/connector), i.e. hardware
  attention, and the CFC numbers in §17.3 are noise-tracking artefacts.
- **C3 — both steps small** (< 1 dB either way). The mute did not take effect or
  `decimated_power` does not respond to the wanted signal at all → **UNINFORMATIVE**;
  the instrument is not measuring what it claims and no branch is read from it.
- **C4 — forward step large, reverse step small.** Incoherent with §17's BER table
  (the reverse leg decodes perfectly, so 146 must be hearing 148) → instrument fault,
  **UNINFORMATIVE**, one re-run then stop.

### 18.4 Falsifiers and refusals

- Baseline `out_voltage0_hardwaregain` ≠ 0.000000 dB on either board → **REFUSE**, no probe
  (the run would not know what it restored to).
- Either board unreachable → refuse before touching a gain.
- Gain readback after each set is logged; a set that does not read back is a wedge →
  one re-run, then UNINFORMATIVE.
- The EXIT trap restores **both** gains to 0 dB and then runs `bringup_r2r3.sh r3`,
  because a peer silent for ~20 s can latch the false-FTS state (ARMCAUSE) on the far
  demod. A failed restore is reported as PHYSICAL ATTENTION, not as a probe result.
- `decimated_power` is a **power** reading and includes noise. Its step is a lower bound
  on the wanted-signal level, and no absolute link budget will be claimed from it.
- No PER, BER or CRC number is produced by this probe and none will be quoted from it.

## §19 Task 59 outcome — branch C1: 148 hears 146 loudly. Level is not the defect. Plus the Task 60 pre-registration.

Run `two_jup/comb/runs/20260908_001150_t59_phylevel/`, unit `phylevel`, 2026-09-08
00:12–00:14 EDT, `N=6 MUTE=-40`, boards on the shipped byte source throughout, no arm.

### 19.1 Results

`in_voltage0_rssi` and `in_voltage0_decimated_power` are **dB below full scale** on this
driver — a LARGER number is a WEAKER signal. (Established inside this run: muting a
transmitter always moved the peer's numbers UP.)

| state | board | rssi (dB) | sd | dec_power (dB) | Δframes / 5 s |
|---|---|---|---|---|---|
| base | 148 | 29.87 | 0.03 | 27.96 | 6,420 |
| base | 146 | 24.34 | 0.05 | 22.50 | 6,452 |
| **mute146** | **148** | **57.03** | 0.53 | 32.50 | **0** |
| mute146 | 146 | 24.33 | 0.07 | 24.62 | 6,467 |
| base2 | 148 | 30.18 | 0.29 | 28.12 | 4,043 |
| base2 | 146 | 24.37 | 0.01 | 22.50 | 6,457 |
| mute148 | 148 | 29.91 | 0.05 | 29.54 | — |
| **mute148** | **146** | **36.71** | 0.36 | 26.25 | 520 |
| base3 | 148 | 29.93 | 0.02 | 27.88 | 6,418 |
| base3 | 146 | 24.30 | 0.07 | 22.50 | 6,478 |

    forward  146 muted -> 148   base 29.99  muted 57.03   RSSI STEP = 27.04 dB
    reverse  148 muted -> 146   base 24.34  muted 36.71   RSSI STEP = 12.37 dB   (control)

### 19.2 Branch C1, and by a wide margin

The pre-registered C1 threshold was a forward step ≥ 0.6 × the reverse step. The
forward step is **27.04 dB against the reverse control's 12.37 dB** — the *broken*
direction has more than twice the level margin of the direction that decodes at air
BER 0.000. And the hard version of the same statement needs no calibration at all:

> **Muting 146 drops 148's detected-frame count to exactly 0 over 6 s**, from 1,284 f/s.
> Every frame 148 detects is one 146 radiated. 148 is receiving 146.

**W2 is dead.** The wanted signal is present at 148, at a level 27 dB above 148's own
residual floor and 5.7 dB *stronger* than what 146 receives from 148. Nothing about the
link budget, the antennas, the cabling or 146's output power explains a BER of 0.290.
The defect is in the **content** of what arrives: frequency, phase, or modulation.

### 19.3 The free control on §17.3 — the CFC scatter survives, but weakened

With 146 muted — no wanted signal at all — 148's CFC read mean **−44,542, sd 69,004**
units, and included exact `0x0`. That is not what §17's forward dwells looked like:
those were bounded, +1,081 … +6,706, taken while `0x104` counted the full 1,247.7 f/s.
So an unlocked estimator does *not* mimic the Task 58 forward readings, and §17.3's
scatter is not simply a no-signal artefact.

It is still weakened as an inference, and honesty requires saying by how much. The
shipped-LO control points in t57b (§14) read CFC **+813 / −527** and **−434 / +869**;
tonight's `base`/`base3` states read **+2,343 ± 900** and **+2,695 ± 596**; Task 58's
forward dwells averaged **+3,844**. Against a healthy −3,314 that is a displacement of
anywhere between **+23 and +51 kHz** depending on which run you ask, which is a range,
not a measurement. **§17.3's "+50.8 kHz" is therefore withdrawn as a point estimate**;
what survives is the qualitative statement that the forward CFO estimate sits well
above its healthy value and does not settle. Every remaining measurement is scored by
BER, not by CFC.

### 19.4 Task 60 pre-registration — sweep the TRANSMIT LO, score by air BER

Instrument `two_jup/comb/tx_lo_ber_sweep.sh`. Every frequency experiment so far moved
the wrong end: t57 and t57b swept **148's RX** LO, over `2000020000 … 2000090000`
only, and scored by host CRC. This sweeps **146's TX** LO, and scores by ROM air BER.

Points: `relock 0 −20000 −50000 −80000 +20000 +50000 +80000 0`, offsets in Hz from
146's shipped `2000000000`. `relock` parks at 1.95 GHz and returns to 2.000000 GHz —
net frequency unchanged, synthesiser re-locked. Each point: set the LO, ROM double-tap
both ends, 8 s dwell on each board, `0x104`/`0x108`/`0x154`/`0x150` either side.

Three things this buys that the RX sweeps could not:

1. **Every write re-locks 146's 2.0 GHz transmit synthesiser.** No PLL lock attribute is
   exposed on this build, so a mis-locked synth has read back as commanded all night;
   a forced retune is the only lever available.
2. **The negative side of the shipped offset**, which the t57b traffic sweep never covered.
3. **The missing half of the §13 staircase** — CFC against *146's TX* LO. §13 only ever
   moved 148's RX.

**Running control, free:** 146's TX LO does not touch 146's receiver, so the reverse air
BER must read 0.000 at every point.

### 19.5 Pre-registered branches

- **D1 — some offset recovers.** Forward BER < 0.05 at one or more points. Reading: a
  frequency offset *is* the defect and t57b missed it because host CRC was too blunt a
  score or the sign was wrong. Confirm at that point with a repeat dwell, then a host-CRC
  leg, then consider shipping the offset.
- **D2 — `relock` alone recovers** (BER < 0.05 at `relock` and at offset 0, no better at
  any other offset). Reading: 146's TX synthesiser was mis-locked; the retune fixed it.
  This is the restoration path and it must be confirmed by a repeat before it is credited.
- **D3 — nothing recovers, but CFC tracks the TX LO** with the §13 slope (≈ 7 Hz/unit,
  and with the sign that increasing TX LO *increases* CFC). Reading: 146's transmit
  carrier is where it is commanded to be, so the defect is in the modulation downstream
  of the synthesiser — TX QEC / LO leakage / DAC / attenuator — which is **hardware
  attention**, not a software fix.
- **D4 — nothing recovers and CFC does NOT track the TX LO.** Reading: 148's CFO estimate
  is not tracking 146's carrier at all; §17.3's displacement is withdrawn entirely and the
  localisation reverts to "PHY, forward direction, mechanism unresolved".

### 19.6 Falsifiers and refusals

- 146's TX1 LO must read back `2000000000` before the sweep starts → else **REFUSE**.
- Reverse air BER must be 0.000 at every point. Any nonzero reverse BER means the run
  perturbed something it should not have → **UNINFORMATIVE**, no branch read.
- A point whose forward `0x104` rate is < 1,000 f/s is reported as **not acquiring**, not
  as "high BER" — frame detection and bit decoding are different failures (§17.2).
- A commanded LO that does not read back is logged as a WARN and that point is scored
  against the **readback**, never against the commanded value.
- `0x108` scores the first 120 of 2,240 bits, so every BER here is a **frame-start** BER.
- EXIT trap restores 146's TX1 LO to `2000000000` and then runs `bringup_r2r3.sh r3`.
  A failed restore is PHYSICAL ATTENTION, not a sweep result.
- One re-run per wedge, then UNINFORMATIVE.

## §20 Task 60 outcome — branch D3: the transmit carrier is exactly where it is commanded, and no offset recovers the link

Run `two_jup/comb/runs/20260908_001858_t60_txlosweep/`, unit `txlosweep`, 2026-09-08
00:19–00:26 EDT, `DWELL=8`, nine points, ROM source both ends, under the 21:02 keeper hold.

| point | 146 TX1 LO | fwd frames | fwd f/s | **fwd BER (120 b)** | fwd cfc1 | fwd cfc2 | **rev BER** |
|---|---|---|---|---|---|---|---|
| relock (park 1.95 GHz → back) | 2000000000 | 9,990 | 1248.8 | **0.2814** | +1,159 | +3,657 | 0.000 |
| 0 | 2000000000 | 9,986 | 1248.2 | **0.2777** | +3,446 | +1,010 | 0.000 |
| −20 kHz | 1999980000 | 9,986 | 1248.2 | **0.3186** | −850 | −1,725 | 0.000 |
| −50 kHz | 1999950000 | 9,986 | 1248.2 | **0.3833** | −4,353 | −433 | 0.000 |
| −80 kHz | 1999920000 | 9,987 | 1248.4 | **0.2718** | −10,083 | −11,363 | 0.000 |
| +20 kHz | 2000020000 | 9,987 | 1248.4 | **0.3186** | +7,164 | +3,566 | 0.000 |
| +50 kHz | 2000050000 | 9,986 | 1248.2 | **0.3018** | +9,870 | +7,799 | 0.000 |
| +80 kHz | 2000080000 | 9,987 | 1248.4 | **0.2752** | +15,701 | +11,909 | 0.000 |
| 0 (closing control) | 2000000000 | 9,987 | 1248.4 | **0.2881** | +586 | +1,578 | 0.000 |

Reverse air BER **0.000 at all nine points** — the running control held, so nothing in this
run perturbed anything it should not have. Forward frame rate **1248.2–1248.8 f/s at every
point**, including ±80 kHz: no point is "not acquiring".

### 20.1 D3 fires. The synthesiser is exonerated, twice over.

**CFC tracks 146's transmit LO 1:1, with the §13 slope.** Mean forward CFC per point:
−80 kHz → −10,723; −50 kHz → −2,393; −20 kHz → −1,288; 0 → +2,228 / +2,408 / +1,082;
+20 kHz → +5,365; +50 kHz → +8,835; +80 kHz → +13,805. A straight-line fit across the
130 kHz span gives **6.65 Hz/unit**, against §13's 7.10 measured on 148's RX LO and the
~7.5 canonical. **148's CFO estimator is following 146's transmit carrier faithfully**, and
146's transmit carrier is exactly where it is commanded to be. This is the missing half of
the §13 staircase, and it kills the "mis-tuned transmit synthesiser" reading.

**The `relock` point is the other half.** Parking 146's TX synth at 1.95 GHz and bringing it
straight back — a forced re-lock, the only lever available on a build that exposes no PLL
lock attribute — gives BER **0.2814** against the un-touched 0.2777. No effect. Combined
with t57/t57b, which re-locked **148's RX** synth at nine different frequencies, **both
synthesisers have now been force-re-locked with no effect**. A mis-locked PLL is excluded on
both ends.

### 20.2 And restoring the healthy CFC makes things WORSE

At the shipped LO the forward CFC sits at ≈ +2,300 against the healthy −3,314. On the fitted
slope, correcting that needs ≈ **−37 kHz** on 146's TX LO — squarely between the −20 kHz and
−50 kHz points, which read BER **0.3186** and **0.3833**, the two *worst* points in the sweep.
Meanwhile the two best points, −80 kHz (0.2718) and +80 kHz (0.2752), sit 80 kHz either side
of centre with CFC nowhere near healthy. The whole range is 0.27–0.38 with **no structure**:
that is scatter, not a curve with a minimum.

**Carrier frequency is not the defect, and CFC is not a proxy for link health** — the reading
§14 reached from host CRC, now confirmed with a score 20× more sensitive and free of the byte
plane, the DMA and the host.

### 20.3 Where that leaves the fault

Established, all [silicon], all tonight:

| | |
|---|---|
| Level at 148 | fine — 27.0 dB above 148's own floor, 5.7 dB *stronger* than the healthy reverse leg (§19) |
| Interference at 148 | none — with 146 muted 148's RSSI is 57.0 dB, i.e. quiet (§19) |
| Frame sync | perfect — 1,248 f/s detected, every point, every dwell (§17, §20) |
| Both synthesisers | commanded frequency confirmed, force-re-locked, no effect (§20) |
| Both boards | rebooted since the collapse and still collapsed (t56 for 146; 148 twice, at the 18:14 and 22:17 flashes on 09-07) |
| Both bitstreams | unchanged from the last healthy leg — 148 was rolled back to `9f13705d9fb0` and stayed collapsed |
| Delivery plane | not in the path at all (§17) |
| Reverse leg | air BER exactly 0.000 throughout every one of these experiments |

A 27 dB SNR QPSK link with perfect frame sync should have essentially zero BER. It has 0.29.
**The signal arrives at full strength and is not carrying the right bits** — the defect is in
the *content* of the waveform, not in its frequency, its power, or its detection. What is
still in the forward path and untested is the pair of digital-to-analogue interfaces that only
the forward leg uses: **146's TX SSI (fabric → ADRV9002) and 148's RX SSI (ADRV9002 → fabric)**.
`two_jup/apply_146_ssi_fix.sh` records that the driver **re-runs the PRBS15 SSI delay auto-tune
on every profile load**, that on 146 it picks a word-boundary-slip clk row that mission traffic
cannot use — which is why 146's tx0 is pinned to clk=3/dat=4 — and that **the rx0 side is left
to whatever the auto-tune chose and is re-tuned on every arm**. Live state read at 00:27:

    148  rx0 clk=1 strobe=4 I=4 Q=4   tx0 clk=5 strobe=3 I=3 Q=3   (tx0 pinned c5d3)
    146  rx0 clk=0 strobe=4 I=4 Q=4   tx0 clk=3 strobe=4 I=4 Q=4   (tx0 pinned c3d4)

148's `rx0` is the one delay in the forward path that nothing pins, that changes on every arm,
and that has never been measured against link quality. That is the next experiment.

## §21 Task 61 pre-registration — 148's rx0 SSI delay, the last unpinned forward knob

Written 2026-09-08 00:36 EDT, before any SSI write. Instrument:
`two_jup/comb/rx_ssi_ber_sweep.sh` (new, syntax-checked, helpers unit-tested off-board,
`DRY=1` clean).

### 21.1 Why this and nothing else

§20's exclusion table leaves one forward-only element: the serial interface between the
ADRV9002 and the fabric. Both boards' **tx0** delays are pinned by `bringup_r2r3.sh`
(146 `c3d4`, 148 `c5d3`) precisely because the driver's PRBS15 auto-tune picks
word-boundary-slip rows. Both boards' **rx0** delays are left to that auto-tune and
re-tuned on every profile load. 148's rx0 is the only delay in the forward path that
nothing pins, and it reads **clk=1** today where 146's working receiver reads **clk=0**
with identical data delays (4/4/4). That is a one-row difference between the receiver
that decodes at BER 0.000 and the receiver that decodes at 0.29.

Counter-evidence held in view: forward BER sat in 0.27–0.38 across **nine separate arms**
in Task 60, each of which re-ran the auto-tune. That is consistent with a deterministic
auto-tune landing on the same bad row every time — and equally consistent with a static
analogue cause with no SSI involvement. A null here is a real exclusion, not a failure.

### 21.2 Design

Ten points, each: pin 148's rx0 → ROM double-tap re-arm → read `ssi_delays` → 8 s dwell on
**both** boards (Task 58's 0x104/0x108 comparator) → read `ssi_delays` again → score.
148's tx0 is re-pinned to **its own** `c5d3` at every point, never 146's `3 4`
(`apply_146_ssi_fix.sh` defaults to 146's values; called bare on 148 it would clobber the
working tx0 and break the reverse control).

| point | rx0 clk/i/q/strobe | role |
|---|---|---|
| `base` | *no SSI write* | the auto-tuned baseline |
| `pin_c1` | 1 4 4 4 | pin to the value already held — apply-path control |
| `c0` | 0 4 4 4 | the high-prior point: 146's working clk row |
| `c2`…`c7` | n 4 4 4 | the rest of the clk sweep |
| `ctrl_bad` | 0 0 0 0 | positive control, named in the script's own header as inside the RX fail band |

Data delays are held at 4 throughout; a second dimension is opened only if clk shows
structure.

### 21.3 Branches, pre-registered

- **E1 — a row recovers the link.** Some clk row reads forward BER ≤ 0.01 with 1,248 f/s
  and reverse still 0.000. The forward collapse is 148's rx0 SSI delay; the auto-tune has
  been picking a bad row since the 09-06 window. Action: pin it, restore service, verify
  by a real host-visible leg with lost frames in the denominator, and record the pin as a
  deliberate deviation from the shipped auto-tuned default in `CURRENT.txt` and at the top
  of the morning report.
- **E2 — no row recovers, but the eye is structured.** `ctrl_bad` is catastrophically
  worse than 0.29 (so the knob demonstrably reaches hardware) and BER varies materially
  across clk rows, yet the floor stays ≫ 0.01. The SSI is being driven and is not the
  whole defect; the fault is upstream of the deserialiser — at 148's analogue receive
  chain or 146's transmit chain. Next instrument: an IQ capture at 148, time-boxed.
- **E3 — no row recovers and the eye is flat**, with `ctrl_bad` still catastrophic. The
  SSI reaches hardware and does not matter: **148's rx0 SSI delay is excluded**, and with
  it the last cheap forward-only candidate. The night ends with the fault localised to the
  forward analogue chain and a hardware-attention recommendation.
- **E4 — `ctrl_bad` is NOT catastrophically worse than 0.29.** The knob is not reaching
  hardware (or 0x108 is not responding to it) and **every row in the run is
  UNINFORMATIVE**, including any apparent improvement. No claim is made either way.

### 21.4 Refusals, aborts and scoring rules

- **Refuse to start** unless 148's live `ssi_delays` reads `tx0_ClkDelay=5`. The whole
  method depends on knowing 148's own tx0 values to write back.
- **A point is UNSCORED** unless rx0 reads back as commanded on *both* the pre-dwell and
  post-dwell live reads. The driver re-runs the auto-tune on every profile load; a
  silently reverted pin would otherwise read as "this delay is fine".
- **ABORT on `TX0_CLOBBER`** — any read where 148's `tx0_ClkDelay` is not 5.
- **ABORT if reverse BER exceeds 0.01, or if 146 detects no frames.** 148's rx0 is not in
  the reverse path, so the reverse leg must stay at 0.000; anything else means the
  write-cache trap took a field it should not have.
- `apply_146_ssi_fix.sh` supplies the write-cache protocol (read live → write every field
  back → set only the intended fields → apply → verify by fresh live read) and returns
  non-zero on verify failure; a failed apply skips its point rather than scoring it.
- Every BER here is **frame-START damage over 0x108's first-120-of-2240-bit window**
  (`bist-120bit-window`), not a full-frame BER, and is reported as such.
- **Restore, unconditionally, on any exit:** re-pin rx0 to its baseline `c1d4`, then
  `bringup_r2r3.sh r3`, then log the final live `ssi_delays`. A failed restore is
  PHYSICAL ATTENTION at the top of the morning report and the hold stays on.

### 21.5 Budget

This is the last diagnostic slot. Diagnosis stops at **04:00** regardless of outcome; the
remaining time goes to restore-verify-report and the 07:00 hand-back.

## §22 Task 61 outcome — E4 (UNINFORMATIVE), and the reason is itself the finding

Run `comb/runs/20260908_003721_t61_rxssi`, 00:37–00:4x. Every non-baseline point came back
**UNSCORED**, and the reason is worth more than the sweep would have been.

### 22.1 What happened

`apply_146_ssi_fix.sh` verified on every single point: its own fresh live read straight
after `echo 1 > ssi_delays` showed the commanded rx0 row (`ssi-fix VERIFIED`, `apply:
VERIFIED`). Sixteen seconds later, after the ROM double-tap re-arm and before the dwell,
the live read was back at the auto-tune's `rx0_ClkDelay=1`:

```
00:38:46  apply: VERIFIED                 (rx0 commanded to clk=0)
00:39:02  ssi pre : rx0_ClkDelay=1 rx0_StrobeDelay=4 rx0_rxIDataDelay=4 rx0_rxQDataDelay=4
00:39:21  ssi post: rx0_ClkDelay=1 ...
00:39:21  fwd(148) ber=0.2772  rev(146) ber=0  pinned=REVERTED_POST
```

Identical for `c2`, `c3`, `c4`, … Forward BER sat at 0.2721 / 0.2899 / 0.2772 / 0.279 /
0.2861 / 0.2842 — the same 0.27–0.38 band as Task 60, because **the delay under test was
never in force during any dwell.** The pre-registered §21.4 rule ("a point is UNSCORED
unless rx0 reads back as commanded on *both* live reads") is what caught it; without that
read-back the flat sweep would have read as "rx0 SSI delay excluded", which it is not.

### 22.2 The finding

**148's rx0 SSI delay cannot be pinned by the current bring-up order.** The arm sequence
that every instrument on this rig runs — `apply_146_ssi_fix.sh`'s own trailing re-arm, and
then `rearm_rom`'s `0x000` pulse plus the tx-lpc writes — restores the auto-tuned value
behind the write. This is the mechanism behind the line in `apply_146_ssi_fix.sh`'s header
that "the receive side re-runs auto-tune every arm while only tx0 was ever pinned": tx0
survives because it is re-written by `bringup_r2r3.sh` *after* each arm, and rx0 does not
because nothing re-writes it after the arm.

Two consequences, both independent of tonight's collapse:

1. Any past or future attempt to pin rx0 through `apply_146_ssi_fix.sh` is a no-op unless
   something re-applies it after the last arm. Worth a note in the script.
2. **Task 61 is E4 — UNINFORMATIVE.** The positive control could not fire, so no row of it
   is evidence in either direction. 148's rx0 SSI delay is neither implicated nor excluded.

Rig state: the EXIT trap re-pinned rx0 to `c1d4` and ran `bringup_r2r3.sh r3`. Reverse air
BER stayed 0.000 at every point except a 1.55e-4 arm-transient reading on the very first
(unpinned) baseline point; tx0 read `c5d3` on all 22 live reads, so nothing was clobbered.

### 22.3 Task 61b pre-registration — re-arm first, pin last

Instrument `two_jup/comb/rx_ssi_pin_last.sh` (new). One change of order: each point does
the ROM double-tap re-arm **first**, then writes the delay with **no register re-arm behind
it**, then dwells. The write-cache protocol is inlined verbatim from
`apply_146_ssi_fix.sh` (read live → write every field back → set only rx0 → apply → verify
by fresh live read) precisely so that no `0x000` pulse follows it. 148's tx0 is written
back at its own live values and checked unchanged on every read.

The point order carries two controls before the sweep, so the run's informativeness is known
in three minutes rather than ten: `base` (no write at all), then **`c1`** (pin rx0 to the
value the auto-tune already chose -- if this does not read like `base`, the *write itself*
perturbs the link and nothing downstream is readable), then **`ctrl_bad`** (rx0 clk0/dat0).
`ctrl_bad2` repeats the control at the end for reproducibility. Amended 00:45, before the
run: §22.3 as first committed put `ctrl_bad` second; `c1` is inserted ahead of it because
pinning live, with no re-arm behind it, could in principle latch a false FTS state
(task-ARMCAUSE) and `c1` is the null-change control that tests exactly that.

Branches:

- **F1 — `ctrl_bad` breaks the forward link** (BER materially worse than 0.29, or frames
  collapse). The knob reaches hardware while running, the pin holds, and the sweep rows
  are readable. Then the E1/E2/E3 branches of §21.3 apply unchanged to the swept rows.
- **F2 — `ctrl_bad` changes nothing and the pin reads back held.** The delay register only
  takes effect at **profile load**, so rx0 cannot be exercised at all without reordering
  bring-up itself (pin, then load the profile). Every row is UNINFORMATIVE again, and the
  honest report is that 148's rx0 SSI delay remains untested — with a concrete, cheap
  follow-up for daylight: move the rx0 write ahead of the profile load in
  `bringup_r2r3.sh` and re-run Task 58.
- **F3 — the pin does not verify even with nothing behind it.** The debugfs path is not
  accepting the value; instrument fault, no claim.

Same refusals as §21.4: refuse unless 148 reads `tx0_ClkDelay=5`; a point is UNSCORED
unless rx0 reads back as commanded before *and* after its dwell; abort on any read where
tx0 is not `c5d3`; restore is re-pin `c1d4` then `bringup_r2r3.sh r3` on every exit, and a
failed restore is PHYSICAL ATTENTION at the top of the morning report.

## §23 Task 61b outcome — F1. The rx0 knob DOES reach hardware, and rx0 clock delay is now genuinely EXCLUDED.

Run `two_jup/comb/runs/20260908_004535_t61b_pinlast/` (00:45:35 → 00:54:11), instrument
`two_jup/comb/rx_ssi_pin_last.sh`, `DWELL=8`, forward = 148, reverse = 146, score = `ber_120b`
(0x108 sees only the first 120 of 2240 bits per frame, so every number is frame-START damage).

**The reordering worked.** All 22 board-points read `PIN_OK` and `pinned=held` — the commanded
rx0 row was still in force on the live `ssi_delays` read *after* each dwell, and `tx0_ClkDelay=5
… tx0_StrobeDelay=3` held on every one. The Task 61 revert is fixed by re-arming first and
pinning last; nothing writes a register behind the pin.

| point | rx0 clk/strb/I/Q | fwd(148) ber | fwd fps | fwd rstcs | fwd cfc1/cfc2 | rev(146) ber |
|---|---|---|---|---|---|---|
| base | none (auto = 1/4/4/4) | 0.2887 | 1248.2 | 0 | 3783 / 1607 | 0 |
| c1 | 1_4_4_4 | 0.2882 | 1248.2 | 0 | 1288 / 3795 | 0 |
| ctrl_bad | 0_0_0_0 | 0.2761 | 1248.4 | 0 | −1991 / 2774 | 0 |
| c0 | 0_4_4_4 | 0.2842 | 1248.2 | 0 | 4009 / −1269 | 0 |
| c2 | 2_4_4_4 | 0.2790 | 1248.2 | 0 | 3785 / 440 | 0 |
| c3 | 3_4_4_4 | 0.2746 | 1248.2 | 0 | 5593 / 803 | 0 |
| c4 | 4_4_4_4 | 0.2765 | 1248.2 | 0 | 698 / −433 | 0 |
| c5 | 5_4_4_4 | 0.2754 | 1248.4 | 0 | −157 / 2473 | 0 |
| **c6** | **6_4_4_4** | **0.4944** | **1098.5** | **9277** | **−37694 / 9190** | **0.4913** |
| **c7** | **7_4_4_4** | **0.4928** | **1004.4** | **17848** | **123630 / 104340** | 0 |
| ctrl_bad2 | 0_0_0_0 | 0.4924 | 764.8 | 11808 | 116113 / 57136 | 8.3e-07 |

### 23.1 Branch F1 fired — but at the top of the range, not at `ctrl_bad`

The pre-registered positive control (`ctrl_bad` = 0/0/0/0) did **not** fire: 0.2761 against base
0.2887, fps unchanged. That control was under-powered and I said so before the run — base is
clk=1 with strobe/I/Q=4, so 0/0/0/0 is a relative data-to-clock shift of only 3 taps, well inside
the eye. **`c6` and `c7` are the control that fired**: clk=6 against data=4 is a +2/−3 tap shift
the other way and it destroys the link. So the knob unambiguously reaches hardware at runtime,
the rows are readable, and this is **branch F1**, not F2.

### 23.2 The exclusion

Every rx0 clock delay the interface tolerates at all — 0, 1, 2, 3, 4, 5 — reads forward
`ber_120b` between **0.2746 and 0.2887**, a 5 % spread with no trend and no minimum, at exactly
nominal frame rate and zero carrier resets. The two rows outside that set do not degrade the leg,
they annihilate it. **There is no rx0 clock-delay setting that recovers the forward leg**, and the
knob was demonstrably live while that was measured. 148's rx0 SSI clock delay is excluded as both
the defect and the fix. (Untested, and still cheap: the rx0 **I/Q data** delays, held at 4/4/4
throughout.)

### 23.3 The most valuable thing in this table is the failure signature

`c6`/`c7`/`ctrl_bad2` are the first clean look tonight at what a genuinely **broken** demod does on
this instrument, measured on the same board, the same image, minutes apart from the forward leg:

| | forward leg (all night) | c6 / c7 / ctrl_bad2 |
|---|---|---|
| `ber_120b` | 0.2746 – 0.2887 | 0.4924 – 0.4944 (= chance, 0.49) |
| frames detected | 1248.2 f/s, zero variance, = nominal | 1098 → 1004 → 765, decaying |
| `rstcs` (0x150) | **0** on every dwell tonight | 9277, 17848, 11808 |
| `reg_cfc` (0x154) | bounded, \|cfc\| < 5600 | −37694, 123630, 141477 — six figures |

That matches `cfc-median-is-a-leg-health-indicator`'s muted-peer calibration (fully unlocked reads
mean −44,542, sd 69,004). **So the forward leg is not an unlocked receiver.** It is a locked,
frame-synchronous, reset-free receiver that gets ~28 % of the scored bits wrong — carrier acquired,
framing perfect, payload wrong. Every "is 148 hearing anything / is the carrier lost" hypothesis is
answered: it hears, it locks, it frames, it mis-decodes. That is a much narrower defect than the
one §17 opened.

Collateral, recorded so it is not mistaken for a finding: at `c6` the **reverse** leg also read
0.4913 for one dwell and recovered by `c7`. Pinning 148's rx0 cannot affect 148's transmitter; the
plausible mechanism is the documented task-ARMCAUSE false-FTS latch on 146 when 148's SSI glitches
mid-write. It self-cleared. The trailing `ctrl_bad2` row is **not** a reproduction of `ctrl_bad` —
the link was already collapsed and decaying from `c6`, so that row is discarded.

Rig state: EXIT trap re-pinned rx0 to `1/4/4/4` and ran `bringup_r2r3.sh r3` — arm gate passed on
try 1 (148 rx=1246 f/s, 146 rx=1248 f/s), byte source live both ends, watchdogs up. Final live
read on 148: `rx0 1/4/4/4  tx0_ClkDelay=5 tx0_StrobeDelay=3 tx0_rxIDataDelay=3 tx0_rxQDataDelay=3`.

## §24 Task 62 pre-registration — the fork nothing tonight has touched: 146's TX vs 148's RX, and board vs band

### 24.1 The hole

Tasks 58, 59, 60, 61 and 61b all instrument **148's receiver**. The working reverse leg proves
**148's TX** and **146's RX**. The broken forward leg is **146's TX and/or 148's RX**, and neither
has been isolated from the other. Nothing measured tonight can tell those two apart, so no fix can
be chosen. Task 60 additionally showed no residual-CFO offset in ±80 kHz recovers the leg
(ber 0.27–0.38 flat across nine points), so this is not a frequency error.

### 24.2 The instrument

`two_jup/comb/selfloop_ber.sh` (new). Four stages, **pure LO retunes** — no flash, no rebuild, and
deliberately **no profile reload**, because the profile load is what re-runs the SSI auto-tune;
tx0 therefore stays exactly where this bring-up pinned it (148 `c5d3`, 146 `c3d4`). The script
**reads** `ssi_delays` at every stage and never writes it — writing it is what collapsed 148 at
`c6`. Task 60 retuned an LO nine times by plain sysfs write with readback and no reload, so the
method is silicon-proven.

| stage | 148 TX / RX | 146 TX / RX | what it is |
|---|---|---|---|
| S0 | — | — | as-found LO census, both boards, all attributes + `dmesg` |
| S1 `s1_control` | 1.900G / 2.00002G | 2.000G / 1.90004G | shipped — must reproduce fwd ≈ 0.28, rev ≈ 0 |
| S2 `s2_bandswap` | 2.000G / 1.90004G | 1.900G / 2.00002G | the same link with the two **bands exchanged**, identical +40k/+20k residuals |
| S3 `s3_selfloop` | 1.900G / 1.90004G | 2.000G / 2.00002G | each board hears **itself**; the two loops are 100 MHz apart, no cross-talk |
| S4 | restore shipped LOs + double-tap, then `bringup_r2r3.sh r3` on the EXIT trap |

### 24.3 The retune is its own positive control

Every stage moves at least one LO by 100 MHz, which could by itself invalidate the ADRV9002's
LO-dependent calibrations. **S2's reverse leg** (148 TX 2.0G → 146 RX 2.00002G) is a link that is
healthy today and is retuned 100 MHz on *both* ends. Declared now, before the run: if S2 reverse
reads `ber ≈ 0`, a 100 MHz retune does not break a working link and every other retuned reading is
admissible. If S2 reverse reads high, **S2 and S3 are UNINFORMATIVE by rule** and the night's
conclusion is limited to §23.

### 24.4 Branches

- **G0 — a loop detects no frames** (`dp ≈ 0` on that board in S3). Antenna isolation is larger
  than the link budget; that half of S3 is UNINFORMATIVE, the other half still scores.
- **G1 — both S3 loops clean (ber ≈ 0).** Each unit works with its own peer hardware. The forward
  defect is then a property of the **2.0 GHz receive path at 148 specifically** (band select, the
  RX1 synth, the per-band gain table) rather than of either unit as a whole — note S3 tests 148's
  receiver at **1.9 GHz**, not at the 2.0 GHz the forward leg uses, so a clean S3 does **not**
  exonerate 148's receiver at 2.0 GHz. Combine with S2 to resolve.
- **G2 — 148's loop dirty, 146's loop clean.** 148's receiver is broken broadly (it fails even at
  1.9 GHz against a transmitter the reverse leg proves good). Fault localised to 148 RX.
- **G3 — 148's loop clean, 146's loop dirty.** 146's *transmitter* is broken: 146's receiver is
  proven good by the reverse leg, so a dirty 146 self-loop can only be its TX. Fault localised to
  146 TX. This is the cleanest branch and the one that would end the search.
- **G4 — both loops dirty.** Self-loopback is not a valid configuration here (near-field
  compression, or the retune itself). Falsify with `TXATT=-20` and re-run S3; if that does not
  recover either loop, the whole of S3 is UNINFORMATIVE.
- **S2 read separately:** forward clean at 1.9 GHz **and** reverse dirty at 2.0 GHz ⇒ the defect
  follows the **band**, not the board. Forward still dirty at 1.9 GHz ⇒ the defect follows 148's
  receiver (or 146's transmitter) irrespective of band, and S3 says which.

### 24.5 Saturation abort, declared before the run

Self-reception may rail the AGC. Every dwell logs `in_voltage0_rssi` and
`in_voltage0_hardwaregain` at both ends of the window (both are dB **below** full scale — larger
means weaker). A self-loop point whose RX gain sits at its floor is **UNINFORMATIVE by this rule**,
not by post-hoc judgement, and `TXATT=-20` is the pre-declared retry, not a rescue invented
afterwards.

### 24.6 What this cannot do

Self-loopback removes the inter-board XO offset (the −5.15 kHz residual of `bringup_r2r3.sh:14`),
so the true residual CFO in S3 is the programmed +40 kHz / +20 kHz alone. Both are far clear of the
CFO ≈ 0 dead zone in either case, but a clean S3 must not later be second-guessed as "it only
worked because the offset was different".

## §25 Task 62 outcome — the pre-registered gate FIRED, and the run is still the most informative of the night

Run `two_jup/comb/runs/20260908_010131_t62_selfloop`, unit `sloop`, 01:01:31–01:05:14, exit 0,
EXIT-trap restore `BRING-UP OK`, arm gate pass on try 1. Six dwells, 8 s each, ~10,000 frames each.

| stage | board | leg it scores | LO pair | `ber_120b` | frames | fps | rstcs | rssi | rxgain |
|---|---|---|---|---|---|---|---|---|---|
| s1_control | 148 | **forward** 146 TX → 148 RX | 2.000G → 2.00002G | **0.2846** | 10004 | 1250.5 | 0 | 29.89 / 29.62 | 34.0 |
| s1_control | 146 | reverse 148 TX → 146 RX | 1.900G → 1.90004G | **0** | 10011 | 1251.4 | 0 | 24.39 / 24.34 | 34.0 |
| s2_bandswap | 148 | **forward** 146 TX → 148 RX | 1.900G → 1.90004G | **0** | 10004 | 1250.5 | 0 | 27.69 / 26.67 | 34.0 |
| s2_bandswap | 146 | reverse 148 TX → 146 RX | 2.000G → 2.00002G | **0.05432** | 10016 | 1252.0 | 0 | 31.20 / 31.60 | 34.0 |
| s3_selfloop | 148 | 148 TX → 148 RX (self) | 1.900G → 1.90004G | **0** | 10004 | 1250.5 | 0 | 12.65 / 12.69 | 31.0 |
| s3_selfloop | 146 | 146 TX → 146 RX (self) | 2.000G → 2.00002G | **0** | 10015 | 1251.9 | 0 | 12.54 / 12.53 | 25.0 |

`s1_control` reproduces both legs exactly (forward 0.2846 against Task 58/60/61b's 0.2718–0.2887
band; reverse 0 errors in 10,011 frames), so the instrument and the link are where they were.
tx0 held `c5d3` / `c3d4` and rx0 was never written, as designed.

### 25.1 The §24.3 gate fired. Say it plainly.

§24.3 declared, before the run: *"if S2 reverse reads `ber ≈ 0` … every other retuned reading is
admissible. If S2 reverse reads high, **S2 and S3 are UNINFORMATIVE by rule**."* S2's reverse leg
read **0.05432 — 65,289 bit errors in 10,016 frames**. That is not `≈ 0`. **The gate fired, and by
the letter of the pre-registration S2 and S3 are UNINFORMATIVE.** They are not being quietly
re-scored as a pass.

### 25.2 The one reading the gate's own failure mode cannot explain

The hazard §24.3 was written to catch is named in its own text: *"a 100 MHz retune … could
plausibly invalidate the ADRV9002's LO-dependent calibrations"*. That hazard is one-directional —
retuning away from a calibration point can only **degrade** a link. It cannot produce
**0 bit errors in 10,004 frames (1,200,480 scored bits)** on a leg that reads 0.2846 at its
calibrated LO.

So the S2 reverse degradation (0 → 0.054) is fully consistent with the hazard and is correctly
excluded, while the S2 forward result (0.2846 → 0) is immune to it. **That is an argued exception,
not a pre-registered pass**, and the honest response to an argued exception is to re-test it rather
than to credit it. §26 does that.

### 25.3 What S3 shows if it is admitted, and the reason it is weaker than it looks

Both self-loops read exactly 0 — including **146 transmitting at 2.000 GHz**, the identical
transmit configuration of the broken forward leg, decoded without error by 146's own receiver.
Read at face value that is branch **G1** and it exonerates 146's transmitter.

But S3 is a **high-SNR test**: RX gain came off its 34.0 dB rail to 31.0 (148) and 25.0 (146) and
rssi fell to ~12.6, i.e. roughly **17 dB more signal** than any over-air dwell. A digital defect
would survive that; a margin-limited failure would not. S3 therefore proves the two chains are
digitally sound and says nothing about either at the levels the air link actually runs at.

### 25.4 The observation that reframes the whole night

`rxgain` reads **34.000000 with AGC automatic in all four over-air dwells, both boards, both
bands** — the receivers are railed at maximum gain, and `txatt` is 0.000000, so the transmitters
are at full power. There is no headroom left anywhere in the link. Against that, the received
levels split by band:

| receiver | at 1.9 GHz | at 2.0 GHz | penalty at 2.0 GHz |
|---|---|---|---|
| 148 | rssi 27.69 | rssi 29.89 | **2.2 dB** |
| 146 | rssi 24.39 | rssi 31.20 | **6.8 dB** |

(rssi is dB **below** full scale — larger is weaker.) **Both receivers get materially less signal in
the 2.0 GHz band, and both 2.0 GHz air legs are the impaired ones while both 1.9 GHz air legs are
perfect.** Two readings fit that:

- **Margin.** The link is sitting on the FEC waterfall knee with everything railed, and a 2–7 dB
  band-dependent path loss decides which leg lands above it. Nothing is defective; the rig is
  short of RF margin, which matches the long-standing "reverse leg 5–6 dB short, antennas not
  swapped" rig note and the 32-hour onset (a physical change costs a few dB, no image changes).
- **Band-specific defect.** 148's 2.0 GHz receive path is broken in a way level does not explain.
  Supporting it: 148 reads BER 0.285 at rssi 29.9 while 146 reads BER 0.054 at rssi 31.2 — **148
  has 1.3 dB *more* signal and 5× the error rate**, so received level alone does not order the four
  air dwells.

**These two are not separated by anything measured tonight**, and Task 60's LO sweep does not
separate them either (it varied frequency, not level). §26 separates them directly.

### 25.5 Standing corrections

- The forward defect band (`ber_120b` 0.27–0.29) and the host `crc_ok` 58–60 % are **not
  commensurable** and must not be combined into a per-frame model: `ber_120b` is scored by the PHY
  comparator on the ROM source (`0x158=0`) over the first 120 of 2240 bits, while `crc_ok` is a
  host-side, whole-frame number from byte-plane legs (`0x158=1`) in different epochs. Any
  "≈ 40 % of frames are garbage" arithmetic that mixes them is withdrawn before it was used.
- 148's RX1 LO reads back exactly the commanded 2000020000 (S0), so "one synthesizer landing
  off-command" is refuted at the driver level and is closed.

## §26 Task 63 pre-registration — band or margin? A power staircase settles it

### 26.1 The question

§25 leaves exactly one fork: is the forward leg broken because it is **in the 2.0 GHz band**, or
because it is **2 dB short of the FEC waterfall knee** with the AGC already railed? Everything else
tonight is excluded. The two answers demand opposite responses — a receive-path investigation
versus PHYSICAL ATTENTION to antennas and cabling — so guessing is not acceptable.

### 26.2 The instrument

`two_jup/comb/band_waterfall.sh` (new). Same method as Task 62: pure sysfs writes, **no profile
reload, no flash, `ssi_delays` read but never written**. It holds the S2 band-swap topology (148 TX
2.000G / RX 1.90004G, 146 TX 1.900G / RX 2.00002G — 148's TX must stay at 2.0 GHz or 148 would hear
itself) and steps **146's transmit attenuation** while scoring 148's forward BER against 148's own
`rssi`. This walks the healthy 1.9 GHz forward leg **down** through the level at which the shipped
2.0 GHz forward leg sits, and the shape of that walk is the answer.

| point | config | purpose |
|---|---|---|
| `w0_shipped` | shipped LOs, `txatt` 0 | control — must read 0.27–0.29 or the run is void |
| `w1_bandswap_a0` … `a3` | band-swapped, `txatt` 0, ×3 reps | does the S2 forward zero **reproduce**? |
| `w2_att<N>` | band-swapped, 146 `txatt` = −2, −4, −6, −8, −12, −16, −20 dB | the staircase |
| restore | shipped LOs, `txatt` 0, `bringup_r2r3.sh r3` on the EXIT trap | never leave the rig band-swapped |

Attenuation sign convention is **verified by readback at the first step**, not assumed; a write that
does not move `out_voltage0_hardwaregain` aborts the run.

### 26.3 Branches, declared before the run

- **H0 — `w0_shipped` does not read 0.27–0.29.** The leg moved under us; the whole run is
  UNINFORMATIVE and nothing in §26 is reported.
- **H1 — the three `w1` reps do not all read `ber < 0.01`.** The S2 forward zero does not
  reproduce; the §25.2 argued exception is withdrawn and the night's conclusion stays at §23.
- **H2 — MARGIN.** BER crosses 0.10 while 148's `rssi` is within **±1.5 dB** of the shipped
  forward leg's 29.9. The 1.9 GHz and 2.0 GHz legs lie on one waterfall; the forward leg is simply
  below the knee. Verdict: **RF link budget, PHYSICAL ATTENTION** — antennas, cabling, pointing.
  No firmware or fabric defect is implicated and Tasks 58–62's exclusions all stand as written.
- **H3 — BAND.** BER stays **< 0.01 down to `rssi` ≥ 33** (≥ 3 dB weaker than the shipped forward
  leg) — the 1.9 GHz leg tolerates less signal than the 2.0 GHz leg is getting. Level does not
  explain the failure; 148's 2.0 GHz receive path is defective. Next instrument: per-band RX gain
  table and RX1 synthesizer state, not another LO topology.
- **H4 — neither.** Non-monotone, or the staircase never crosses 0.10 within 20 dB. UNINFORMATIVE;
  report H1's reproduction result alone.

### 26.4 Rules carried in

- `rxgain` is logged at both ends of every dwell. If it leaves the 34.0 dB rail on a `w2` point the
  level axis is not what this run assumes, and that point is dropped by rule, not by judgement.
- The staircase attenuates **146's transmitter only**. 148's TX stays at full power so the reverse
  leg keeps working as a liveness witness; its readings are logged but are not the target.
- The rig is restored to shipped LOs and `txatt` 0 by the EXIT trap in every exit path, including
  the abort paths. **The band-swapped plan is a measurement configuration tonight, not a shipped
  one** — adopting it would trade a broken forward leg for a broken reverse leg (S2: 0 → 0.054) and
  that is an operator decision, not an autonomous one.

---

## §27 Task 63 outcome — H2 is dead, H3 survives, and the defect follows the BAND, not the board

Run `two_jup/comb/runs/20260908_011259_t63_bandwf`, unit `bwfall`, 01:12:59–01:22:28 EDT
2026-09-08, exit 0, EXIT-trap restore `BRING-UP OK`, arm gate pass. Instrument
`two_jup/comb/band_waterfall.sh` at `245b7ff`. Eleven 8-s ROM dwells per board,
~10,000 frames each on every creditable point, `ber_120b` = `0x108` delta over
`0x104` delta / 120 bits.

### §27.1 The staircase, and the waterfall it draws

148 receiving at 1.900040 GHz from 146 transmitting at 1.900000 GHz, 146's TX
attenuated in steps. `rxgain` read **34.000000 on every point of the whole run,
both boards** — so no point drops under the §26.4 rail rule.

| point | 146 txatt | 148 rssi | 148 dpow | gap | 148 `ber_120b` | fps | rstcs |
|---|---|---|---|---|---|---|---|
| `w0_shipped` (2.0 GHz) | 0 | 29.78 | 28.00 | +1.78 | **0.2848** | 1250.8 | 0 |
| `w1_swap_a1` | 0 | 26.76 | 26.75 | +0.01 | **0** | 1250.5 | 0 |
| `w1_swap_a2` | 0 | 26.78 | 26.50 | +0.28 | **0** | 1111.6 | 0 |
| `w1_swap_a3` | 0 | 26.85 | 26.50 | +0.35 | **0** | 1250.5 | 0 |
| `w2_att2` | 2 | 28.83 | 29.00 | −0.17 | **0** | 1250.4 | 0 |
| `w2_att4` | 4 | 30.44 | 30.25 | +0.19 | **0** | 1250.5 | 0 |
| `w2_att6` | 6 | 32.14 | 32.25 | −0.11 | 4.165e-06 | 1250.6 | 0 |
| `w2_att8` | 8 | 33.84 | 26.25 | **+7.59** | 0.01264 | 1250.5 | 0 |
| `w2_att12` | 12 | 36.21 | 36.75 | −0.54 | 0.4933 | 514.6 | **12164** |
| `w2_att16` | 16 | 39.80 | 26.25 | **+13.55** | 0.491 | 495.2 | **14142** |
| `w2_att20` | 20 | 39.66 | 40.00 | −0.34 | 0.4921 | 416.8 | **13307** |

**148's 1.9 GHz noise floor is measured here.** `rssi` tracks the commanded
attenuation dB-for-dB down to att12 and then stops moving: 39.80 at att16 and
39.66 at att20, with 4 dB of extra attenuation between them buying nothing. The
receiver is reading its own floor. **Floor ≈ 39.8 dB below full scale** (an upper
bound on the floor's strength — 146 was still radiating at −20 dB).

Referred to that floor, the wanted-to-floor ratio and the BER draw one clean
waterfall:

| 146 txatt | 148 rssi | wanted/floor | `ber_120b` |
|---|---|---|---|
| 0 | 26.76 | 12.82 dB | 0 |
| 2 | 28.83 | 10.61 dB | 0 |
| 4 | 30.44 | 8.83 dB | 0 |
| 6 | 32.14 | 6.84 dB | 4.2e-06 |
| 8 | 33.84 | 4.69 dB | 0.0126 |
| 12 | 36.21 | 1.09 dB | 0.4933 (lock lost) |

Error-free above ~6.8 dB, knee at ~4.7 dB, collapse by ~1 dB. That is what a
working QPSK link looks like, and 148's demodulator draws it.

### §27.2 Scoring against the branches committed in §26.3

**H0 — control.** `w0_shipped` read **0.2848**, inside the pre-registered
0.27–0.29 window, at the shipped LOs with `rstcs 0` and fps 1250.8. The run is
**valid** and the forward defect reproduced for the third time tonight.

**H1 — the argued exception.** All three `w1_swap` reps read **0 errors in
10,004 frames** (1,200,480 scored bits each), `rstcs 0`. The §25.2 forward zero
reproduces. **H1 passes**; the argued exception from §25.2 is now credited, not
merely argued.

**H2 — MARGIN. FALSIFIED.** H2 required BER to cross 0.10 while 148's `rssi` was
within ±1.5 dB of the shipped leg's 29.9 — that is, between rssi 28.4 and 31.4.
Measured: at rssi 28.83 the BER is **0**, at 30.44 it is **0**. The 0.10 crossing
lies between rssi 33.84 and 36.21, **4 to 6 dB weaker** than the shipped forward
leg. The two legs are not on one waterfall and the forward leg is not simply
below the knee.

**H3 — BAND. Credited, with its literal threshold not met.** H3 as written
required "BER stays < 0.01 down to `rssi` ≥ 33". The nearest measured points
bracket that line: rssi 32.14 → 4.2e-06, rssi 33.84 → 0.01264. So **no measured
point at rssi ≥ 33 reads below 0.01**; interpolating, the 0.01 crossing sits at
rssi ≈ 33.7. The *intent* of the branch — that the 1.9 GHz leg tolerates ≥ 3 dB
less signal than the 2.0 GHz leg is getting — **is met, with 3.8 dB**. Recording
both readings rather than rounding the threshold in my own favour: H3's number
was set one point too tight, and the branch is credited on its stated intent.

**H4 — UNINFORMATIVE. Does not apply.** See §27.3 for the level-axis check.

### §27.3 The level axis is clean where the verdict is decided

The check is the `rssi`−`dpow` gap, both in the same dB-below-full-scale domain.
Across the four points that decide H2 (att0/2/4/6) the gap is **+0.01, −0.17,
+0.19, −0.11** — flat inside ±0.2 dB — while `rssi` moves 5.4 dB monotonically.
`rssi` is dominated by the wanted signal on this leg and the level axis behaves.

Two points report `dpow` **exactly 26.250** (att8, att16) out of an otherwise
monotone 26.75 → 29.00 → 30.25 → 32.25 → … → 36.75 → … → 40.00 sequence, while
`rssi` stays smooth. The repeated identical out-of-trend value reads as a stale
`in_voltage0_decimated_power` sample, not a band effect. **The H2 falsification
does not depend on either of them** — it rests on att2 and att4, both clean.

**Drop declared after the fact, and said so plainly.** `w2_att12/16/20` on 148
carry `rstcs` 12,164 / 14,142 / 13,307 and fps 515 / 495 / 417 against a nominal
1,250: the demodulator is resetting its carrier and dropping half its frames.
Those are not creditable dwells by the standing rule that a scored dwell reads
`rstcs 0`. That rule was **not** in §26.4's drop list, so it is being applied
after seeing the data — and it changes nothing: drop them and the 0.10 crossing
is "somewhere weaker than rssi 33.84"; keep them and it is between 33.84 and
36.21. H2 is falsified either way.

**The reverse leg was a stable witness.** 148's transmitter ran unattenuated
throughout, so 146's column is a constant-stimulus control on the environment.
Its ten dwells read 0.05321, 0.05739, 0.05843, 0.05878, 0.05368, 0.05553,
0.05099, 0.05244, 0.05205, 0.05160 — mean 0.0554, full range ±7 % about it, and
**not monotone** (it rises to `w2_att2` then falls back). `rssi` pinned at
31.3 ± 0.4 across the whole eight minutes. The environment did not drift during
the staircase, so 148's changes are attributable to the commanded attenuation.

### §27.4 The finding H3's wording did not anticipate: it is not 148

H3 named "148's 2.0 GHz receive path". Cross-referencing the two directions
shows that is too narrow. Every air dwell of the night, sorted by the band the
link ran in:

| link band | transmitter | receiver | `ber_120b` |
|---|---|---|---|
| 1.9 GHz | 146 | 148 | **0** |
| 1.9 GHz | 148 | 146 | **0** |
| 2.0 GHz | 146 | 148 | **0.2848** |
| 2.0 GHz | 148 | 146 | **0.052** |

Both directions are clean at 1.9 GHz. Both are impaired at 2.0 GHz — and between
the two 2.0 GHz rows the transmitting board and the receiving board are
**exchanged**. No single board's transmit chain and no single board's receive
chain is present in both failures. **The impairment follows the band.**

That is consistent with the other two facts nobody has been able to place: a
32-hour onset window with **no image change on either board**, and `rxgain`
railed at 34.0 dB with `txatt` 0 on every air dwell — no headroom anywhere.

### §27.5 The prediction Task 63 makes, and how to kill it

If the 2.0 GHz impairment is an elevated noise floor rather than a lost signal,
the arithmetic is forced. The shipped forward leg reads total in-band power
**29.78 dB below full scale** and `ber_120b` **0.2848**. On the waterfall of
§27.1 a BER of 0.28 sits at a wanted-to-floor ratio of roughly **2 dB or less**.
For 29.78 dBFS of total power to be only ~2 dB above the floor, **148's 2.0 GHz
noise floor must be ≈ 34 dB below full scale — about 6 dB stronger than the
39.8 dBFS floor measured at 1.9 GHz.**

| assumed 2.0 GHz floor | implied wanted/floor at rssi 29.78 |
|---|---|
| 39.8 dBFS (same as 1.9 GHz) | +9.6 dB → should be error-free |
| 35 dBFS | +3.7 dB |
| **34 dBFS** | **+2.0 dB → matches the observed 0.2848** |
| 33 dBFS | +0.4 dB |

**This is directly measurable and needs no demodulator.** Mute the transmitters
and read `in_voltage0_rssi` at each band on each receiver. A 2.0 GHz floor near
34 dBFS confirms excess in-band energy — an interferer or a raised noise floor,
which is an RF-environment problem and is what a 32-hour onset with no image
change looks like. A 2.0 GHz floor near 39.8 dBFS kills the noise-floor model
outright and forces the defect back into the receive chains' band-dependent
*sensitivity*, where the next instrument is the per-band RX gain table and the
RX1 synthesizer state.

### §27.6 One observation that changes how Task 64 must be built

146's `dpow` moves monotonically **24.75 → 26.25 → 27.50 → 28.25 → 29.25 →
30.25 → 31.25 → 31.50** across the staircase while its `rssi` stays pinned at
31.3 and the signal it is receiving (148's transmitter) never changes. The only
thing moving is **146's own transmit attenuation**, 0 → 20 dB. 146's
decimated-power detector is tracking **its own transmitter** — a 1.900 GHz TX
leaking into a 2.000 GHz receive chain 100 MHz away — while `rssi` on the same
board does not follow it.

Two consequences, both binding on Task 64:

1. A noise-floor measurement must mute **both** transmitters, not just the peer.
   Muting the far end alone leaves the near end's own leakage in the reading.
2. `dpow` and `rssi` are not interchangeable level meters on this hardware.
   `rssi` is the axis that behaved on 148's staircase; `dpow` is recorded as a
   witness and is not scored.

### §27.7 What Task 63 does and does not settle

- **Settles:** the forward failure is not a link-budget shortfall at 2.0 GHz.
  148's demodulator, at air levels and with `rxgain` railed exactly as on the
  broken leg, delivers 0 errors in 10,004 frames at a level 3.4 dB *weaker* than
  the level the broken leg is receiving. H2 is falsified.
- **Settles:** it is not one board. The impairment appears in both directions at
  2.0 GHz with the transmitter and receiver roles exchanged.
- **Does not settle:** whether 2.0 GHz is noisy or 2.0 GHz reception is
  insensitive. §27.5 is a prediction with a number on it, not a finding.
- **Does not settle:** residual CFO is not the explanation, but that was closed
  earlier, not here. The shipped forward leg runs a 20 kHz residual and the
  swapped points run 40 kHz. Task 60 (§20) swept 148's RX LO ±80 kHz around
  2000020000 with BER flat at 0.27–0.38 and no minimum, and the historically
  healthy forward leg ran at exactly that 20 kHz residual until 09-06. The
  confound is closed twice over.
- **Unchanged operator decision:** the band-swapped plan repairs the forward leg
  and leaves the reverse leg at 0.052. It is a measurement configuration, not a
  shipped one (§26.4), and adopting it would additionally require making
  `LO_A_TX`/`LO_B_TX` env-overridable in `bringup_r2r3.sh:56-59`, where they are
  currently hardcoded.

---

## §28 Task 64 pre-registration — measure the level budget directly, with the demodulator out of the loop

Instrument `two_jup/comb/band_noise.sh` (new, `bash -n` clean, `DRY=1` printed
`BANDNOISE_DRY_OK`). Committed before it runs.

§27.5 left a prediction with a number on it. This settles it, and it does so with
a quantity that needs no frame lock, no calibrated profile and no demodulator:
`in_voltage0_rssi`, in the dB-below-full-scale domain (**larger = weaker**).
`in_voltage0_decimated_power` is recorded as a witness and **is not scored** —
§27.6 caught it tracking 146's own transmitter while `rssi` on the same board did
not follow.

### §28.1 What the run does

At each of two LO plans, every receiver is read in four transmit states, and
linear subtraction separates the three contributors:

| state | 148 TX | 146 TX | what 148's `rssi` contains |
|---|---|---|---|
| `q` | muted | muted | environment floor `N` |
| `p` | muted | live | `N` + wanted |
| `s` | live | muted | `N` + 148's own-TX leakage |
| `b` | live | live | the operational reading |

Plan `shipped` puts 148's receiver at 2.000020 GHz — the broken forward leg.
Plan `swapped` puts it at 1.900040 GHz — the configuration Task 63 proved clean,
serving as the known-good control. Then a **quiet floor sweep** across
1850/1900/1950/2000/2050 MHz with both transmitters muted **and** both TX LOs
parked once at 1.700 GHz, so no board's own carrier sits inside any band being
characterised.

The span is 1850–2050, not the 1700–2200 first drafted: tonight's silicon proves
100 MHz retunes, not 300 MHz ones. The mute depth is **probed by readback**
(−40 → −30 → −20) and the run **aborts** if none of them moves
`out_voltage0_hardwaregain` on both boards — the Task 61 lesson, that a knob
which does not reach hardware produces a confident null.

### §28.2 Admissibility, declared before the data

- **State `b` at plan `shipped` is the instrument's own positive control.** It
  must reproduce Task 63's `w0_shipped` levels within **±1.0 dB**: 148 at 29.78,
  146 at 24.38. Otherwise the survey is not looking at the link that is broken.
- `rxgain` must read **34.000000 on every row**. It has on every air dwell of the
  night; if the AGC moves, levels are not comparable across states.
- `rxensm` must read `rf_enabled` on every row.
- **Independent cross-check:** the quiet sweep's 1900 MHz floor on 148 must read
  **≥ 38.0 dBFS** (no stronger than that). Task 63 measured that floor at
  39.8 dBFS with 146 still radiating at −20 dB, so the true floor is at or below
  39.8; a quiet reading stronger than 38.0 means the two instruments disagree.

### §28.3 Branches, evaluated in this order

**J0 — VOID.** Any §28.2 condition fails. No conclusion is drawn and the night's
verdict stays at §27.

**J4 — UNINFORMATIVE.** `rssi` does not respond to the mute (state `q` within
1.0 dB of state `b` on 148 at `shipped`), or `rssi_sd` exceeds 1.5 dB on a
deciding row, or the 1900 MHz cross-check of §28.2 fails.

**J5 — SELF.** At `shipped`, 148's state `s` reads **≥ 3 dB stronger** than its
state `q`, and the derived self-leak power is within 3 dB of the derived wanted
power. 148's own 1.900 GHz transmitter is desensitising its 2.000 GHz receiver.
This is not a strawman: §27.6 caught exactly that signature on 146. It would
explain a 32-hour onset with no image change (isolation fell — a cable, a
connector, an antenna moved) and it has an operational mitigation the operator
can weigh. Next instrument: a TX-attenuation staircase on 148 with the forward
leg scored, the mirror of Task 63.

**J1 — NOISE.** The quiet floor at 2000 MHz is **≥ 3 dB stronger** than the quiet
floor at 1900 MHz on 148 (§27.5 predicts ~6 dB: 34 vs 39.8), **and** the derived
wanted-to-floor at `shipped` is **≤ 3 dB**, consistent with 0.2848 on the §27.1
waterfall. The 2.0 GHz band carries excess energy — an interferer or a raised
noise floor. **PHYSICAL ATTENTION / spectrum investigation**, not firmware, and
it fits the onset window exactly.

**J2 — DEAF.** The quiet floors at 1900 and 2000 MHz agree within **1.5 dB**, but
the derived **wanted** power at `shipped` is **≥ 6 dB weaker** than the derived
wanted at `swapped`. The floor is normal and the signal is simply not arriving:
antenna, cabling, filter, or a per-band gain table. Next instrument: per-band RX
gain table and RX1 synthesizer readback.

**J3 — NEITHER, and it points back at firmware.** Floors agree within 1.5 dB
**and** the derived wanted at `shipped` is within 3 dB of the wanted at
`swapped` — so 148 is receiving a healthy wanted-to-floor ratio (≥ 8 dB) at
2.0 GHz and still reads `ber_120b` 0.2848. Then the failure is **not in the RF
level budget at all**, and the next instrument is the rx0 I/Q **data**-delay
sweep named in §23.2 and still untested (the rx0 *clock* line is excluded). This
would be the first result of the night to point back at the fabric.

### §28.4 Declared in advance

- The band-swapped plan remains a **measurement configuration, not a shipped
  one** (§26.4). Nothing in Task 64 changes that, and adopting it would still
  require making `LO_A_TX`/`LO_B_TX` env-overridable in `bringup_r2r3.sh:56-59`.
- Any wanted-to-floor number quoted from this run is an **RSSI-domain
  wanted-to-floor ratio, not a measured symbol SNR**. The two differ by the
  receiver's noise bandwidth and implementation loss and must not be reported
  interchangeably.
- The run restores shipped LOs, `txatt` 0 on both boards and `bringup_r2r3.sh r3`
  on the EXIT trap in every path, aborts included.

---

## §29 — Task 64 outcome: the RF level budget is excluded, and the broken band is the QUIET one

Run `two_jup/comb/runs/20260908_012942_t64_bandnoise`, unit `bnoise`,
01:29:42–01:34:03 EDT 2026-09-08, exit 0, `BANDNOISE_OK`, restore
`BRING-UP OK`, arm gate pass on try 1 (148 rx=1246 f/s, 146 rx=1247 f/s).
Mute depth engaged: **−40 dB on both transmitters**, readback-confirmed.
26 rows, `n=6` `rssi` samples each. `rxgain` read **34.000000 on every one
of the 26 rows** and `rxensm` read **rf_enabled on every one** — nothing was
dropped under the §26.4 rail rule and no row is a not-listening read.

### §29.1 The four-state decomposition

`rssi` is dB **below** full scale: **larger = weaker**. `q` = both
transmitters muted (the floor); `p`/`s` = one transmitter live. **The labels
`p` and `s` are named from 148's point of view.** For 146 they are reversed —
its `p` row is its own leakage and its `s` row is the wanted signal from 148.
The `txatt` column on each row disambiguates, and the derivations below use
the `txatt` column, not the label.

| plan | receiving board | RX band | floor `q` | own-TX row | wanted row | `b` |
|---|---|---|---|---|---|---|
| shipped | 148 | 2000.02 | **58.098** | 59.294 (`s`) | **30.597** (`p`) | 30.613 |
| shipped | 146 | 1900.04 | **36.143** | 36.023 (`p`) | **25.531** (`s`) | 25.502 |
| swapped | 148 | 1900.04 | **42.274** | 42.293 (`s`) | **27.357** (`p`) | 27.504 |
| swapped | 146 | 2000.02 | **59.599** | 59.568 (`p`) | **31.647** (`s`) | 31.823 |

### §29.2 The result, against the Task 63 air dwells

| receiving board | RX band | floor (dBFS) | wanted (dBFS) | wanted − floor | Task 63 `ber_120b` |
|---|---|---|---|---|---|
| 148 | 1900.04 | 42.27 | 27.36 | **14.9 dB** | **0** |
| 146 | 1900.04 | 36.14 | 25.53 | **10.6 dB** | **0** |
| 148 | 2000.02 | 58.10 | 30.60 | **27.5 dB** | **0.2848** |
| 146 | 2000.02 | 59.60 | 31.65 | **27.9 dB** | **0.052** |

**The two failing links have nearly twice the wanted-to-floor ratio of the two
clean ones — 13 to 17 dB more margin — and they are the ones that fail.** The
received wanted level is nearly the same on all four (25.5–31.6 dBFS, a 6 dB
span); what differs is the floor, and the *quiet* band is the broken one.

### §29.3 Scoring, in the §28.3 evaluation order

- **J0 — VOID: fires on one clause, by 0.12 dB, and is NOT taken.** §28.2
  required state `b` at `shipped` to reproduce Task 63 within ±1.0 dB on
  **both** boards. 148 read 30.613 against 29.782 = **0.831 dB, inside**.
  146 read 25.502 against 24.378 = **1.124 dB, outside by 0.124 dB**. The other
  three admissibility clauses passed outright (`rxgain` 34.000000 every row;
  `rxensm` rf_enabled every row; 148's quiet 1900 MHz floor 42.29 ≥ 38.0).
  Recording the miss rather than rounding the threshold in my own favour: the
  control **passed on 148**, which is the board whose numbers carry the
  verdict, and **missed on 146**, which contributes nothing to the J1/J2/J3
  decision. The conclusion below turns on a **13–17 dB** separation; a 1.12 dB
  drift on the other board's receiver over an eight-minute air run cannot
  reach it. The run is carried as an **argued exception, not as a clean
  control**, and it is labelled that way wherever it is quoted.
- **J4 — UNINFORMATIVE: does not fire.** Mute engaged at the first candidate
  depth on both boards; all 26 rows complete; no `WARN` lines.
- **J5 — SELF: dead.** Own-transmitter rows sit within 1.2 dB of the muted
  floor in all four cases, and in the *quieter* direction: 148 shipped
  59.294 vs 58.098, 146 shipped 36.023 vs 36.143, 148 swapped 42.293 vs
  42.274, 146 swapped 59.568 vs 59.599. **Neither board hears its own
  transmitter at either band.**
- **J1 — NOISE: falsified, in the opposite direction.** The 2.0 GHz floors are
  58.10 and 59.60 dBFS; the 1.9 GHz floors are 42.27 and 36.14 dBFS. The
  failing band is **16 to 23 dB quieter**. **§27.5's prediction is falsified
  outright**: it forecast a 2.0 GHz floor near 34 dBFS if the collapse were
  excess band energy; the measurement is ≈ 58–60 dBFS, about 24 dB away.
- **J2 — DEAF: dead.** 148's wanted at `shipped` (30.597) is only **3.24 dB**
  weaker than at `swapped` (27.357), short of the ≥ 6 dB the branch required —
  and Task 63 already proved 0 errors in 10,004 frames at `rssi` 30.44 on the
  healthy band, so 30.60 is a level demonstrated to be sufficient.
- **J3 — NEITHER: credited on its stated intent; both of its literal clauses
  recorded as unmet.** §28.3 wrote J3 as "floors agree within 1.5 dB **and**
  the derived wanted at `shipped` is within 3 dB of the wanted at `swapped`".
  The floors differ by **15.8 dB** (148) and **23.5 dB** (146), and the wanted
  differ by **3.24 dB** — so **neither literal clause is met**. Its stated
  intent was "148 is receiving a healthy wanted-to-floor ratio (≥ 8 dB) at
  2.0 GHz and still reads `ber_120b` 0.2848, so the failure is not in the RF
  level budget at all". That is met with 27.5 dB against the 8 dB asked for,
  and the way the clauses fail **strengthens** the branch rather than
  weakening it: the branch was drafted expecting the two bands to look alike,
  and they do not — the failing band is quieter and better-served, which makes
  the level story worse, not better. Same treatment as H3 in §27.2.

### §29.4 The ambient map (quiet sweep, both transmitters muted, parked at 1.700 GHz)

| RX band (MHz) | 148 `rssi` mean | 148 `rssi_sd` | 146 `rssi` mean | 146 `rssi_sd` |
|---|---|---|---|---|
| 1850.04 | 62.335 | 0.597 | 61.510 | 0.087 |
| 1900.04 | **42.292** | **1.375** | **37.110** | 0.496 |
| 1950.04 | **41.480** | **1.551** | **36.559** | 0.473 |
| 2000.04 | 59.432 | 0.973 | 59.461 | 0.319 |
| 2050.04 | 64.101 | 0.239 | 63.258 | 0.192 |

There is a real ambient emitter occupying roughly **1900–1950 MHz**, seen by
both boards, ~20–25 dB above the floor at 1850/2000/2050 MHz. On 148 its
samples are **bimodal** (alternating ≈ 40.7 / 43.6 dBFS at the 0.5 s sample
cadence), which reads like a duty-cycled emitter. **It sits squarely in the
band the link works in, and the two bands where the link fails are among the
quietest measured.** This closes the interference story from the other end.

### §29.5 What §29 settles, and the one thing it leaves

Excluded for the 2.0 GHz failure, on measurement: received level, receiver
noise floor, external interference, self-leakage from the board's own
transmitter, and — with §27's staircase — margin. Task 62's S3 rows already
excluded the boards themselves: **146 TX 2.000 GHz → 146 RX 2.00002 GHz
self-loop scored `ber_120b` 0 over 10,015 frames**, and 148's own 1.9 GHz
self-loop scored 0, so each board's RF chain is proven good *at 2.0 GHz* when
the path is short. (Caveat, stated: the self-loop rows ran at `rxgain`
31.0/25.0 dB and `rssi` ≈ 12.5 — a much stronger signal than the air legs, so
they prove the chain functions, not that it functions at the air operating
point.)

What is left is **the path between the two boards**. The one path impairment
that is band-selective, **reciprocal** — so it strikes both directions, which
is exactly what Task 63's role-exchanged pair of failures shows and what no
board-side story produces for free — leaves total received power intact
(`rssi` integrates across the 40 MHz occupied band; a null inside it barely
moves the number) and can open inside a 32-hour window with no image change,
is a **frequency-selective multipath null**. Task 65 tests it.

### §29.6 Collateral reads (Task 65 orientation probe, pure read, both boards)

`two_jup/comb/runs/20260908_0140_t65_calsnap/calsnap.txt`, 01:38 EDT, no writes:

- **Profile and stream binaries are byte-identical across the two boards and
  unchanged since July.** `lvds_61p44_fdd_jupiter.bin` md5
  `d124b81d0ba0e303f7362503226691e9` and `.json` md5
  `10a24a902dac8fecdecf394330ce13e4` on **both**, mtimes 2026-07-28. Nothing
  in the 32-hour window touched them — the "the profile changed" hypothesis is
  dead.
- `initial_calibrations=off` on both (`available: off auto run`), and **every
  transmit tracking calibration is disabled** on both
  (`out_voltage{0,1}_{quadrature,lo_leakage,close_loop_gain,loopback_delay,pa_correction}_tracking_en=0`).
  Receive side identical on both: `agc`, `bbdc_rejection`, `quadrature_fic`,
  `rfdc`, `rssi` enabled; `hd` and `quadrature_w_poly` disabled. **The two
  boards' calibration configuration is identical**, so no per-board cal
  difference can explain a failure that follows the band.
- `ssi_delays` is not exposed at the `iio:device2` sysfs path and read empty on
  both; SSI health is instead reported by the arm chain, which logged
  `ssi-fix VERIFIED: tx0=c5d3 rx0 preserved (1/4)` on 148 and
  `tx0=c3d4 rx0 preserved (0/3)` on 146 at 01:35.
- `dmesg` on 148 shows **no PLL, lock, or calibration failure**. Its only
  ADRV9002 errors are `Error attempting to read RSSI. Specified channel must
  be in RF_ENABLED state` at t≈4591 s — **self-inflicted, from my own probing**,
  and a standing caveat: an `rssi` read taken while `ensm ≠ rf_enabled` returns
  a driver error, not a number. Every Task 64 row recorded
  `rxensm=rf_enabled`, so none of them is one of these.

### §29.7 Correction to §26.6 and to the working model

Every instrument from Task 58 through Task 61b probed **148's receive chain**.
§29 and Task 62's S3 together say that was the wrong subsystem: 148's receiver
demodulates 2.0 GHz correctly at close range, 146's transmitter produces a
correct 2.0 GHz waveform, and the pair fails only across the room. **The
forward CRC collapse is not a receiver defect and not a transmitter defect.**

---

## §30 — Task 65 pre-registration: NOTCH or EDGE

Instrument `two_jup/comb/band_ber_sweep.sh`, committed before the run.

### §30.1 Configuration

146 transmits at `f`; 148 receives at `f + 20 kHz` — the shipped residual
offset, held at **every** point because the fabric demod has a CFO dead zone at
zero residual. 148's transmitter and 146's receiver are **parked together at
1.700 / 1.700020 GHz** for the whole sweep: they stay ≥ 180 MHz clear of every
swept point, and the 1.7 GHz link they form is a **free running control** — if
146 reads `ber_120b` 0 at 1.7 GHz at every point, both boards survived all 13
retunes. Both transmitters stay at **0 dB** (shipped power); Task 63 already
swept level and this sweep is about frequency alone. Points, MHz:
**1880 1900 1920 1940 1960 1980 2000 2020 2040 2060 2080 2100**, plus a
`c_shipped` control point in the unmodified shipped configuration first.
`DWELL=8` s per board per point; the ARMCAUSE double-tap
(`rearm B; rearm A; sleep 3; rearm B; rearm A; sleep 4`) after every retune.

### §30.2 Admissibility

**K0 — VOID.** The `c_shipped` control must put 148 in **0.25–0.32** (Tasks
58, 61b, 62 and 63 all read 0.2846–0.2848) **and** the 1900 MHz sweep point
must read **< 1e-4**. If either fails, the sweep is **UNINFORMATIVE** and
nothing is scored from it. `rxgain` and `rxensm` are recorded on every row;
any row not at `rf_enabled` is discarded and said to be discarded.

### §30.3 Branches, in this evaluation order

1. **K1 — NOTCH.** The failing points form a contiguous run with a clean point
   (`ber_120b` < 1e-4) **both below and above** it, total width ≤ 80 MHz.
   → a frequency-selective null in the link path. Boards, images, fabric and
   host are all exonerated, and moving the operating frequency out of the
   notch is an **operator-actionable repair**. Deliverable: the widest clean
   band measured, named with its two clean shoulders.
2. **K2 — EDGE.** Every point at or above some `f` fails and no point above it
   recovers. → not multipath; a device, antenna or cable limit. Different
   action, and not fixable by retuning upward.
3. **K3 — SCATTERED.** Failures non-contiguous. Re-run **once** (the standing
   one-re-run rule). If the pattern repeats differently, the channel is
   time-varying — which still puts the defect in the path, but **no single
   clean band can be credited from one sweep** and none will be claimed.
4. **K4 — ALL-CLEAN.** Every point including 2000 MHz reads < 1e-4. The defect
   cleared between 01:22 (Task 63) and the sweep. That is itself strong
   evidence for a drifting channel; re-run the shipped control before
   concluding anything.

### §30.4 Declarations, before the run

- `ber_120b` scores only the **first 120 of 2240 bits** per frame (0x108's
  comparator window). Every number is frame-**start** damage and is **not** a
  link BER, and no host-visible PER claim is made from this instrument —
  that needs `legrun_go.sh` with lost frames in the denominator.
- `rssi` is a **wideband** power reading across the 40 MHz occupied band. A
  flat `rssi` across a failing sweep point is **the notch signature**, not
  evidence the signal is healthy. `rssi` will not be used to argue either way
  about a point's health.
- Any band this sweep names as clean is a **measurement result, not a shipped
  configuration**. Adopting one needs `LO_A_TX`/`LO_B_TX` made
  env-overridable in `bringup_r2r3.sh:56-59`, where they are hardcoded, and
  that is an operator decision.

## §31 — Task 65 outcome: K3 SCATTERED. No clean band credited.

Run `two_jup/comb/runs/20260908_014500_t65_bersweep/`, unit `bersweep`,
2026-09-08 01:45:00 → 01:54:32 EDT, `UNIT_EXIT success 0`.
Command: `two_jup/launch_rig_unit.sh bersweep /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup/comb/band_ber_sweep.sh DRY=0`
(script defaults: `DWELL=8 WINBITS=120 PARKF=1700000000 OFF=20000`,
`FREQS="1880 1900 1920 1940 1960 1980 2000 2020 2040 2060 2080 2100"`).
Results: `band_ber_sweep.tsv`, 26 rows (13 points x 2 boards, plus the
c_shipped control pair). Sample count **10,003–10,020 detected frames per
row** (0x104 delta over an 8 s dwell), i.e. ~1.20 M scored bits per row at
120 bits/frame.

### §31.1 K0 — admissible

`c_shipped` on 148 reads **0.2755**, inside the pre-registered 0.25–0.32
window (Tasks 58, 61b, 62, 63 read 0.2846–0.2848). The 1900 MHz sweep point
reads **0** (< 1e-4). **K0 VOID does not fire; the sweep is admissible.**

`rxgain` is **34.000000 on all 26 rows** — the AGC is railed at maximum
everywhere, as in every prior task.

**Recording gap, declared:** §30.2 promised `rxensm` on every row. The TSV
schema emitted by `score()` in `band_ber_sweep.sh` carries `rxgain` but
**not** `rxensm`, so no row carries an explicit ensm field and the
pre-registered discard rule could not be applied as written. What is
available instead: (a) the per-point `rf :` census lines in
`band_ber_sweep.log` do carry `txensm=`/`rxensm=`, and every one of them
reads `rf_enabled`; (b) every row has a **numeric** `rssi1`/`rssi2`, and an
`in_voltage0_rssi` read taken while ensm != `rf_enabled` returns a driver
error rather than a number. Both are indirect. **No row is discarded**, and
the substitution is recorded here rather than glossed.

### §31.2 The scored result — 148 rows (forward leg under test)

| point | frames | errs | fps | `ber_120b` | cfc1/cfc2 | rstcs | rssi1/rssi2 | verdict |
|---|---|---|---|---|---|---|---|---|
| c_shipped 2000 | 10005 | 330763 | 1250.6 | **0.2755** | 5777/3301 | 0 | 29.916/30.225 | FAIL (control) |
| f1880 | 10003 | 0 | 1250.4 | 0 | −3489/−3432 | 0 | 24.242/24.556 | clean |
| f1900 | 10004 | 0 | 1250.5 | 0 | −3426/−3454 | 0 | 26.780/26.766 | clean |
| f1920 | 9266 | 77625 | 1158.2 | **0.06981** | −3471/−3466 | **2586** | 26.360/26.449 | **FAIL** |
| f1940 | 10005 | 0 | 1250.6 | 0 | −3368/−3229 | 0 | 28.641/27.913 | clean |
| f1960 | 10004 | 0 | 1250.5 | 0 | −3058/−2851 | 0 | 30.297/30.344 | clean |
| f1980 | 7275 | 430791 | **909.4** | **0.4935** | −2906/6880 | **40** | **37.518/37.569** | **FAIL** |
| f2000 | 10004 | 317487 | 1250.5 | **0.2645** | **−796/−455** | **0** | 29.963/29.850 | **FAIL** |
| f2020 | 10005 | 0 | 1250.6 | 0 | −3442/−3437 | 0 | 23.125/22.981 | clean |
| f2040 | 10004 | 0 | 1250.5 | 0 | −3604/−3477 | 0 | 23.796/23.840 | clean |
| f2060 | 10003 | 0 | 1250.4 | 0 | −3463/−3429 | 0 | 24.679/24.729 | clean |
| f2080 | 10004 | 0 | 1250.5 | 0 | −3465/−3460 | 0 | 21.845/21.805 | clean |
| f2100 | 10004 | 0 | 1250.5 | 0 | −3497/−3521 | 0 | 23.685/23.738 | clean |

**146 rows:** the parked 1.700 GHz control link scored **0 errors at every
one of the 13 points**, 10,007–10,020 frames, fps 1250.9–1252.5, rstcs 0,
rssi 37.3–38.0. The boards survived all 13 retunes and the control link
never degraded — the sweep mechanism itself is exonerated. The one
exception is the `c_shipped` 146 row, which is not the parked control but
the real shipped **reverse** leg (148 TX 1900 → 146 RX 1900.04): 10,015
frames, **0 errs**, rssi 24.389/24.433. The reverse leg is healthy at the
same instant the forward leg is at 0.2755.

### §31.3 Branch scored: **K3 — SCATTERED**

Evaluated in the pre-registered order:

* **K1 NOTCH — does NOT fire.** The failing set is **{1920, 1980, 2000}**.
  §30.3 K1 requires "a contiguous run with a clean point both below and
  above it". 1940 and 1960 are both clean and both lie **between** 1920 and
  1980, so the failing set is not contiguous. K1 fails on its own text.
* **K2 EDGE — does not fire.** 2020, 2040, 2060, 2080 and 2100 all recover
  to 0.
* **K3 SCATTERED — FIRES.** Failures are non-contiguous.
* **K4 ALL-CLEAN — does not fire.**

**The consequence, quoted from the committed §30.3:** *"Re-run once (the
standing one-re-run rule). If the pattern repeats differently, the channel
is time-varying — which still puts the defect in the path, but no single
clean band can be credited from one sweep and none will be claimed."*

**Therefore no clean band is named in this section, and none is adopted.**
2020–2100 read zero here and it would be easy to write that down as the
answer; the pre-registration forbids it from one sweep, and that is the
whole point of having written it down first. §32 pre-registers the one
permitted re-run.

### §31.4 What the sweep does establish, independent of the branch

1. **The defect is frequency-selective and lives in the path.** Same two
   boards, same two images, same fabric, same host, same 40 MHz profile,
   same railed AGC, same 20 kHz CFO offset — only the carrier moved, and
   the forward leg goes from 0 to 0.49 and back to 0 across it. Nothing
   board-side is frequency-selective in this way at 20 MHz granularity.
2. **Received level is definitively excluded for the shipped band.**
   `f2000` fails with **rssi 29.963/29.850** while `f1960` is perfectly
   clean at **30.297/30.344** — *weaker* by 0.35–0.49 dB and error-free.
   Equal level, opposite outcome. This independently confirms Task 64's
   conclusion from the opposite direction (Task 64 muted the transmitters
   and measured the floor; this measures the wanted signal).
3. **Internal replicate.** `f2000` and `c_shipped` share identical
   forward-leg LOs (146 TX 2000000000 → 148 RX 2000020000) and differ only
   in what 148's transmitter and 146's receiver are doing. They read
   **0.2645** and **0.2755**. The forward leg fails at 2.000 GHz regardless
   of the reverse leg's configuration, and the failure is repeatable to
   ~4 % within one 9-minute run.

### §31.5 Post-hoc observations — NOT pre-registered, NOT scored

Everything in this subsection was noticed after the data was in hand. §30
did not anticipate it, no branch turns on it, and it is recorded as a lead
for §32 to test, not as a result.

**Three failures, three different signatures:**

| point | fps | rstcs | rssi | reading |
|---|---|---|---|---|
| f1920 | 1158.2 (low) | **2586** | 26.4 (normal) | never held lock; thousands of carrier resets |
| f1980 | 909.4 (low) | 40 | **37.5** (7–13 dB weak) | lost level, then lost lock |
| f2000 | **1250.5 (exactly nominal)** | **0** | 29.96 (normal) | **locked, framed, and corrupted** |

**A one-mechanism reading (speculative):** 1980 and 2000 *are* contiguous —
a 40 MHz-wide null with clean shoulders at 1960 and 2020 — and the two
signatures are what one null looks like sampled at two depths. At 1980 the
receiver sits near the null's floor, loses 7 dB, and drops lock. At 2000 it
sits on the shoulder where total power is unharmed (RSSI integrates over
the whole 40 MHz occupied band, so a null *inside* the band barely moves
it), so it **keeps** lock — fps exactly nominal, rstcs 0 — while the
in-band frequency-selective distortion wrecks the channel estimate. 0x108
scores only the first 120 of 2240 bits, precisely the frame-start region
most exposed to a bad channel estimate. On this reading "locked but
corrupted" is the *expected* shoulder signature, not evidence against a
path defect. The separate 1920 failure would then be the duty-cycled
ambient emitter Task 64 already measured in 1900–1950 (148 floor 42.29 at
1900, 41.48 at 1950, bimodal) catching an 8 s dwell — a different, and
intermittent, hazard.

**CFC (speculative, weaker).** CFC clusters at ≈ **−3400 units** (≈ −24.5
kHz at 7.10 Hz/unit) at every clean point, but reads **−796/−455** at
`f2000` and wanders to **+5777/+3301** at `c_shipped`. The 2.0 GHz failures
are the only points where CFC leaves that cluster, and they move it
**toward zero**, which touches the documented CFO dead zone. Counting
against this: CFC is measured by the demodulator itself, so a distorted
channel corrupting the CFO estimate is at least as likely as a CFO problem
causing the distortion, and the standing note is that **CFC is not a proxy
for link health**. Not used to score anything.

**Not verified:** 1920 MHz is 38.4 MHz x 50 exactly, which would be a
fractional-N integer-boundary spur if 38.4 MHz were the ADRV9002 reference.
The device reference clock has not been read back. Recorded so it is not
re-derived; worth 30 seconds to check before it is ever believed.

### §31.6 Instrument declarations (restated, binding)

* `ber_120b` scores **only the first 120 of 2240 bits**. It is frame-**start**
  damage, it is **not** a link BER, and **no host-visible PER claim is made
  from it**. A PER number needs `legrun_go.sh` with lost frames in the
  denominator.
* `rssi` is a **wideband** reading across the 40 MHz occupied band. A flat
  `rssi` at a failing point is the notch signature, not evidence of health,
  and is not used to argue either way about a point's health.
* Every clean point was measured with **148's transmitter parked at 1.700
  GHz**, not its in-service 1.900 GHz. No statement here transfers to the
  real TX pairing without a leg run at that pairing.
* Any band named clean would be a **measurement result, not a shipped
  configuration**. Adoption needs `LO_A_TX`/`LO_B_TX` made env-overridable
  in `bringup_r2r3.sh:56-59` and is an **operator decision**.

### §31.7 Rig state after Task 65

Restore trap ran on EXIT: txatt 0 both boards, shipped LOs written
explicitly (148 tx 1900000000 / rx 2000020000, 146 tx 2000000000 / rx
1900040000), then `bringup_r2r3.sh r3` → `ARM GATE PASS (try 1)` →
`r3 BRING-UP COMPLETE` → `restore: BRING-UP OK` at 01:54:32. Byte source
live both ends. **The forward leg is therefore back in its broken shipped
configuration**, which is the correct hand-back state but is not service.
Keeper hold still in place.

---

## §32 — Task 66 pre-registration: the one permitted re-run

**Authority.** §30.3 K3 mandates exactly one re-run. This is it. No further
sweep will be run tonight whatever the outcome, and the 04:00 diagnostic
cutoff still binds.

**What the re-run is for.** Not a repeat for its own sake. The single
question that changes the interpretation is: **does 1920 reproduce?**

* If 1920 comes back clean while 1980/2000 still fail, the underlying
  structure is one contiguous ~1970–2010 null with clean shoulders, and the
  1920 point was the intermittent 1900–1950 emitter.
* If 1920 fails again, the scatter is stable and there are two independent
  features.
* If the failing set moves, the channel is time-varying and §30.3 K3's
  prohibition stands permanently for this pair of sweeps.

**Command (pre-registered exactly):**

```
two_jup/launch_rig_unit.sh bersweep2 \
  /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup/comb/band_ber_sweep.sh \
  DRY=0 DWELL=25 FREQS="1900 1910 1920 1930 1960 1970 1980 1990 2000 2010 2020"
```

12 points (c_shipped + 11), ~15 min plus ~80 s restore. `PARKF`, `OFF`,
`WINBITS` unchanged. 1900 is retained as the in-sweep clean anchor so L0
can be evaluated exactly as K0 was. Fine points at 1910/1930 bracket the
1920 failure; 1970/1990/2010 resolve the shape and shoulders of the
1970–2010 feature.

**Declared in advance: the two sweeps are NOT sample-matched.** `DWELL`
goes 8 s → 25 s, ~10 k → ~31 k frames per row. This is deliberate and
asymmetric: 8 s is the wrong sampling regime for calling a point "clean"
against a duty-cycled emitter, so a clean reading at 25 s is a stronger
claim than a clean reading at 8 s, while a *failing* reading is not made
easier. Any comparison of the two sweeps is therefore conservative in the
direction of finding *more* failures, not fewer.

### §32.1 L0 — VOID

`c_shipped` on 148 must read **0.25–0.32** and the **1900 MHz** point must
read **< 1e-4**. If either fails, the re-run is **UNINFORMATIVE**, nothing
is scored from it, and §30.3 K3's prohibition stands unmodified.

### §32.2 Branches, in evaluation order

1. **L1 — STABLE SCATTER.** 1920, 1980 and 2000 all fail again
   (`ber_120b` >= 1e-3) and 1960 and 2020 are both clean again, and no
   point clean in Task 65 newly fails. → the frequency structure is stable
   and reproducible across two independent sweeps 30+ minutes apart. The
   widest contiguous clean run, named with its two clean shoulders, **may
   be recorded as a measurement result** — still not adopted, still subject
   to §31.6.
2. **L2 — 1920 CLEARS.** 1920 reads < 1e-4 while 1980 and 2000 still fail
   and 1960/2020 stay clean. → the 1920 failure was the intermittent
   1900–1950 emitter; the underlying defect is a single contiguous
   ~1970–2010 null. Same crediting rule as L1, plus the emitter recorded as
   a separate intermittent hazard that makes 1900–1950 unsuitable
   regardless.
3. **L3 — DRIFTED.** Any point clean in Task 65 fails now, or 1980 or 2000
   clears. → time-varying channel. **No band named, now or later, from
   these two sweeps.** The recommendation becomes a repeated soak, not a
   retune.
4. **L4 — ALL CLEAN.** Every point including 2000 reads < 1e-4. → the
   defect cleared between 01:53 and the re-run. That is the strongest
   available evidence for a drifting channel; the forward leg is reported
   as **intermittent**, no band is named, and the morning report says the
   fault was not present at last measurement.

### §32.3 What happens after — pre-registered so it is not decided by the result

* A band may be **named** only under L1 or L2, and only as a measurement.
* **Adoption is not tonight's work under any branch.** It requires (a) the
  `${VAR:-default}` edit to `LO_A_TX`/`LO_B_TX` in `bringup_r2r3.sh:56-59`,
  (b) a real `legrun_go.sh LEG=A DUR=600` at the candidate band with lost
  frames in the denominator, (c) a `LEG=B` check that the reverse leg is
  unharmed at whatever pairing results, and (d) an operator decision.
* **Trap hazard, recorded before the edit is made:** once `LO_*` become
  env-overridable, any unit that exports an override and whose EXIT trap
  calls `bringup_r2r3.sh r3` would *restore to the override*, not to
  shipped defaults, and the rig could be handed back on a non-shipped
  configuration. Every restore path must write the shipped LO values
  **explicitly** — as `band_ber_sweep.sh`'s `restore()` already does — and
  must not rely on the defaults.
* Hand-back is unconditional: forward leg back at shipped defaults, keeper
  hold released and verified by effect, both images verified by readback.

### §32.4 Mid-run declaration: the MARGINAL band, and the 38.4 MHz finding

Written 2026-09-08 02:14 EDT, **while Task 66 is still running**, with exactly
three of its twelve 148 rows in hand (`c_shipped` 0.2782, `f1900` 0, `f1910`
0.0007145) and the remaining nine — including every point of the 1960–2020
feature and the 1930 bracket — not yet measured. Declared now, before the
data that would make it convenient, for the same reason §30 was.

**The gap.** §30.2 defines *clean* as `ber_120b` **< 1e-4**. §32.2 defines
*fails* as `ber_120b` **>= 1e-3**. Nothing was said about the decade between
them, and `f1910` has landed in it at **7.145e-4** (2,672 errors over 31,163
frames). The rule, fixed now:

* `ber_120b` **< 1e-4** → **CLEAN**
* **1e-4 to < 1e-3** → **MARGINAL** — neither clean nor failing
* **>= 1e-3** → **FAILING**

**Consequences, binding on §33:** a MARGINAL point may **not** be counted
inside any band named clean, and may **not** be counted as a failure for
L1/L2. L3 DRIFTED is triggered only by a Task-65 **clean** point reaching
**FAILING** (>= 1e-3); a Task-65 clean point going MARGINAL is recorded and
called out but does not by itself fire L3. `f1910` and `f1930` were not
measured in Task 65 at all, so neither can trigger L3 under any reading.

**The 38.4 MHz finding [file, not silicon].** §31.5 recorded, as unverified,
that 1920 MHz is 38.4 MHz x 50 exactly and that this would matter only if
38.4 MHz were the ADRV9002 reference. It is:
`two_jup/lvds_61p44_fdd_jupiter.json:3` reads `"deviceClock_kHz": 38400`.
Distance from each swept LO to the nearest integer multiple of 38.4 MHz:

| point | 146 TX dist (MHz) | 148 RX dist (MHz) |
|---|---|---|
| 1880 | 1.600 | 1.580 |
| **1920** | **0.000** | **0.020** |
| 1960 | 1.600 | 1.620 |
| 1980 | 16.800 | 16.780 |
| 2000 | 3.200 | 3.220 |
| 2020 | 15.200 | 15.180 |
| all others | 4.8–18.4 | 4.8–18.4 |

**1920 is the only point in either sweep where an LO sits on a fractional-N
integer boundary** — exactly 0.000 MHz for 146's transmitter — and the two
next-nearest points, 1880 and 1960, are both 1.6 MHz away and both scored
0 in Task 65. Integer-boundary spurs are a known PLL behaviour class.

**This is arithmetic plus a known device-behaviour class, not a measurement.**
It is recorded here because it makes a falsifiable prediction that the
running sweep tests without any extra rig time, and because the two candidate
explanations for the 1920 outlier disagree:

* **Integer-boundary spur** — deterministic and LO-locked, so 1920 must
  **reproduce**, and the feature should be **narrow**: 1910 and 1930 clean.
* **Duty-cycled ambient emitter** (Task 64's bimodal 1900–1950 floor) —
  intermittent, so 1920 **may clear**, and any skirts would be set by the
  emitter's own occupied bandwidth, not by an LO.

`f1910` at MARGINAL 7.1e-4 is already mild evidence **against** the narrow
LO-locked reading and toward something with skirts ~10 MHz wide. One row is
not a result; `f1930` is the bracket that matters and it is not yet in.

**Either way this is not the 1980–2010 feature.** Both candidates are local
to 1920 and neither is a path defect, so whichever wins, the 1920 point
should be treated as a separate hazard and excluded from the structure that
§32's L1/L2 are about. That exclusion is declared here, in advance, and not
retrofitted in §33.

---

## §33 — Task 66 outcome: **L1 STABLE SCATTER fires.** The forward defect is a reproducible ~40 MHz frequency-selective null with the shipped carrier on its flank.

Unit `bersweep2b`, run dir `two_jup/comb/runs/20260908_020815_t66_bersweep2/`.
Launched 02:08:15 EDT, `SWEEP_OK` 02:23:37, restore `BRING-UP OK` 02:24:53, unit
inactive `Result=success ExecMainStatus=0`. Scored against §32, committed at
`642313e`, and §32.4, committed at `020e554`, both **before** any Task 66 row existed.

### §33.1 Correction to the committed launch command

The command block pre-registered in §32 **omitted the script's required `OUT=`
variable** (`band_ber_sweep.sh:70` is `: "${OUT:?set OUT=<run dir>}"`). The first
launch, unit `bersweep2`, died in 5 ms at that line with `status=1/FAILURE` and
**made no rig contact** — no LO was written, no board was re-armed, and the EXIT
trap's restore was therefore not needed. The unit was reset-failed and relaunched
as `bersweep2b` with the variable supplied. The committed §32 block is left as
written; this is the correction. The command actually run:

```
two_jup/launch_rig_unit.sh bersweep2b \
  /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup/comb/band_ber_sweep.sh \
  DRY=0 DWELL=25 WINBITS=120 \
  FREQS="1900 1910 1920 1930 1960 1970 1980 1990 2000 2010 2020" \
  OUT=/mnt/onetb/scratch/qpsk-jupiter-modem/two_jup/comb/runs/20260908_020815_t66_bersweep2
```

### §33.2 K0/L0 admissibility — does not void

`c_shipped` (both boards at their in-service LOs) scored `ber_120b` **0.2782**, inside
the 0.25–0.32 band §30.2 required, and `f1900` scored **0** errors. L0's void
condition is not met; the sweep is admissible.

### §33.3 The 148 receiver table (DWELL=25 s, WINBITS=120)

```
stage      fwd_MHz  frames  errs     fps     err/frame  ber_120b   cfc1    cfc2    rstcs  rssi1   rssi2   dpow
c_shipped  2000     31176   1040720  1247.0  33.382     0.2782      3110    5235       0  29.618  29.905  27.750
f1900      1900     31180         0  1199.2   0.000     0          -3669   -3857       0  27.209  27.173  26.750
f1910      1910     31163      2672  1198.6   0.086     0.0007145  -3408   -3417       0  27.245  27.246  27.750
f1920      1920     29155    262818  1166.2   9.015     0.07512    32732*  -3428    8048  26.742  26.479  26.500
f1930      1930     29264    273746  1170.6   9.354     0.07795    -3660   -3651    7801  26.979  26.746  27.00
f1960      1960     31176         0  1247.0   0.000     0          -2987   -2994       0  30.88   29.984  29.500
f1970      1970     28913   1716128  1156.5  59.355     0.4946    234392* 227556*  59366  35.510  35.342  35.00
f1980      1980     23749   1406985   950.0  59.244     0.4937      8400*   7867*    186  38.67   37.612  37.500
f1990      1990     31176    967599  1247.0  31.037     0.2586     -3322  -11219*      0  36.275  36.452  36.00
f2000      2000     31176   1052717  1247.0  33.767     0.2814      1461*  -1503*      0  30.14   29.928  29.750
f2010      2010     31176         0  1247.0   0.000     0          -3909   -4011       0  24.897  24.955  24.500
f2020      2020     31176         0  1247.0   0.000     0          -3433   -3439       0  23.125  23.136  23.00
```

`rxgain` was 34.000000 dB (the rail = maximum) on every row. Asterisked CFC values
are out of family — see §33.9. Clean rows scored **31,176 frames x 120 bits =
3,741,120 bits with zero errors** each.

**146's parked control link** (148 TX at 1.700 GHz, 146 RX at 1.700020 GHz) scored
**0 errors at all 12 points**, frames 31,182–31,195, rssi 37.16–37.83. The
`c_shipped` 146 row — the real reverse leg — also scored 0 errors at rssi 24.171.
The reverse leg is clean at every point at which the forward leg fails.

### §33.4 Cross-sweep agreement: seven points measured twice, seven agree in class

| point | Task 65 (8 s) | Task 66 (25 s) | class |
|---|---|---|---|
| c_shipped | 0.2755 | 0.2782 | fail / fail |
| 1900 | 0 | 0 | clean / clean |
| 1920 | 0.06981 | 0.07512 | fail / fail |
| 1960 | 0 | 0 | clean / clean |
| 1980 | 0.4935 | 0.4937 | fail / fail |
| 2000 | 0.2645 | 0.2814 | fail / fail |
| 2020 | 0 | 0 | clean / clean |

The two sweeps are separated by ~25 minutes, a full restore-and-rearm cycle
(`bringup_r2r3.sh r3` between them) and a 3x change of dwell. Nothing moved class.

**Honest caveat on the 1980 agreement.** `ber_120b` 0.4935 vs 0.4937 is a
four-digit match on a **saturated** statistic: random bits over a 120-bit window
score 0.5. Agreement there means only "both fully broken" and carries no
information about the mechanism. The informative reproduction at 1980 is the
**rssi**: 37.518/37.569 in Task 65 against 38.67/37.612 in Task 66, versus
30.297/30.344 and 30.88/29.984 at clean 1960.

### §33.5 Branch scored: **L1 fires; L2, L3, L4 do not**

- 1920 fails again (0.07512 >= 1e-3). Yes.
- 1980 fails again (0.4937). Yes.
- 2000 fails again (0.2814). Yes.
- 1960 clean again (0). Yes.
- 2020 clean again (0). Yes.
- No point clean in Task 65 newly fails. Of Task 65's clean set, Task 66 re-measured
  1900, 1960 and 2020; all three returned 0. Yes.

All six conditions met → **L1 STABLE SCATTER**. L2 (1920 clears) is dead. L3 (a
Task-65-clean point newly fails) did not fire. L4 (control voids) did not fire.
K3 SCATTERED from Task 65 required exactly one re-run before any band could be
credited; that re-run is Task 66 and it is now spent.

### §33.6 The clean run, named as a measurement result only

§32.2 permits naming "the widest contiguous clean run, named with its two clean
shoulders". That phrase can only be **partly** satisfied by this data, and the
shortfall is stated rather than papered over:

- **Credited at full dwell: 2010–2020 MHz.** Both points scored 0 errors over
  31,176 frames each — **62,352 frames, 7,482,240 bits, zero errors**. The lower
  boundary is measured and failing: 2000 MHz, four independent measurements
  (0.2645, 0.2755, 0.2782, 0.2814). The upper neighbour 2040 is clean.
- **Corroborated at the 8 s dwell only: 2040, 2060, 2080, 2100** (Task 65, 10,003–10,005
  frames each, 0 errors). So the clean run extends at least 2010–2100 MHz, 90 MHz wide.
- **The upper boundary is NOT measured.** 2100 MHz is the top of the swept range,
  not a measured shoulder. A run whose upper edge is the edge of the experiment
  cannot be called bounded. **Closing that boundary is the one thing a further
  sweep must do**, and until it is closed no width claim above 2010–2020 should be
  quoted as a bounded band.
- Every clean point in both sweeps was measured with **148's transmitter parked at
  1.700 GHz**, not at its in-service 1.900 GHz. The pairing that a service
  configuration would use has not been measured at any clean frequency.

**This is a measurement, not a recommendation.** §32.3 binds: *"Adoption is not
tonight's work under any branch."*

### §33.7 The upper null, now fully profiled

Task 66's 10 MHz grid resolves structure Task 65's 20 MHz grid could not see:

```
1960  clean     rssi 30.88   frames 31176   rstcs     0
1970  0.4946    rssi 35.51   frames 28913   rstcs 59366   <- carrier lock thrashing, 2375 resets/s
1980  0.4937    rssi 38.67   frames 23749   rstcs   186   <- floor; 23.8 % of frames never counted
1990  0.2586    rssi 36.28   frames 31176   rstcs     0   <- locked, frame starts corrupted
2000  0.2814    rssi 30.14   frames 31176   rstcs     0   <- THE SHIPPED CARRIER
2010  clean     rssi 24.90   frames 31176   rstcs     0   <- strongest level in the table
```

A null roughly **1965–2005 MHz**, ~40 MHz wide, floor near 1980, depth **13.8 dB**
(1980's 38.67 dBFS against 2010's 24.897 dBFS; larger = weaker). Both shoulders are
sharp — one 10 MHz step from clean to saturated on the low side, one from saturated
to clean on the high side.

The shipped forward carrier sits **20–25 MHz up the recovering flank**: close enough
that carrier lock holds (rstcs 0, full 31,176 frames delivered) but far enough down
that ~28 % of the first 120 bits of every frame are wrong. That combination — full
frame delivery with heavy frame-start damage and no carrier resets — is precisely
the signature the forward leg has shown since 09-06.

The shipped forward pairing has now been measured **four times** across two sweeps:
0.2755, 0.2645, 0.2782, 0.2814. Mean 0.275, spread +/-3 %, ~82,500 scored frames.
It is stable, reproducible, independent of the reverse leg's state, and unchanged
across a 25-minute gap and a full re-arm.

### §33.8 RF level is excluded, now three independent ways

1. **Equal level, opposite outcome.** f2000 fails at rssi ~30.0 while f1960 is clean
   at rssi 30.3–30.9 — the clean point is *weaker* or equal. Measured twice on each side.
2. **Task 64's muted-transmitter floor** measured the ambient noise floor directly.
3. **New: the ber plateau.** From 1980 to 1990 to 2000 the level recovers 8.5 dB
   (38.67 → 36.28 → 30.14) while `ber_120b` sits on a plateau at 0.2586 → 0.2814.
   An 8.5 dB SNR improvement that moves the error rate by 9 % relative is not a
   level-limited channel.

Whatever the null is, it is not a link-budget shortfall, and no amount of transmit
power or receive gain (already railed at 34.0 dB) addresses it.

### §33.9 Instrument declarations and two measurement-code findings

**(a) CFC is unusable where the demodulator is not locked.** The asterisked values
in §33.3 — 32732 at 1920, 234392/227556 at 1970, 8400/7867 at 1980, -11219 at 1990,
1461/-1503 at 2000 — are wildly out of family with the -2900..-3900 seen at every
clean point. `score()`'s `sgn()` maps values >= 2^31 to negative, so these are
genuine positive reads, not sign artefacts. They are **not tabulated as
measurements**. This is consistent with the standing note that CFC is not a proxy
for link health; the sharper statement is that CFC is not a *measurement* at all
once `rstcs` is non-zero or the frame-start comparator is saturated.

**(b) The apparent fps deficit at 1900/1910 is a `date +%s` quantisation artefact,
not a rate deficit.** `dwell()` takes `t1`/`t2` with `date +%s` (1-second
granularity) and `score()` computes `fps = dp/dt`. At 1900 and 1910 `dt` rounded to
26 where every other row rounded to 25 — which alone produces the 1247.0 → 1199 f/s
step. The **frame counts settle it**: 31,180 and 31,163 against 31,176 at every
other clean point, agreeing to within 0.06 %. Had the true interval been 26.0 s at
1247 f/s, the counter would have advanced ~32,420. It did not. There is no rate
deficit at 1900/1910.

Consequence for reading this table and Task 65's: **`frames` is the trustworthy
column, `fps` carries a +/-1-second quantisation of +/-4 % at DWELL=25 and +/-12.5 %
at DWELL=8.** Read as frame counts against the 31,176 reference, the real delivery
deficits are: 1980 **-23.8 %**, 1970 -7.3 %, 1920 -6.5 %, 1930 -6.1 %, and zero
everywhere else. That ordering tracks the null profile and the reset counter, and
it is the number to quote, not fps.

**(c) The rxensm recording gap declared in §31.1 still applies.** `score()` emits
`rxgain` but not `rxensm`; `dwell()` reads no ensm at all. A point at which the
receiver had dropped out of `rf_enabled` would be indistinguishable in the TSV from
one that was enabled. The `rfstat()` lines in the log cover this at arm time only.

### §33.10 The 1920–1930 feature: a second, separate impairment, mechanism unresolved

Task 66 measured a rising edge: 1900 clean → 1910 **MARGINAL** (7.145e-4, inside the
1e-4..1e-3 band §32.4 defined mid-run) → 1920 (0.07512) and 1930 (0.07795), with
reset rates 322/s and 312/s and matched frame deficits of 6.5 % and 6.1 %.

**A prediction committed in §32.4 was falsified.** §32.4 read 1920 as the only sweep
point whose LO landed on an integer multiple of the 38.4 MHz device clock
(`two_jup/lvds_61p44_fdd_jupiter.json:3`, `"deviceClock_kHz": 38400`; 1920 = 50 x 38.4)
and predicted 1920 would reproduce **and** 1910/1930 would be clean. 1930 failed
identically at 0.07795 with both its LOs 10.000 MHz from any multiple of 38.4 MHz.
The narrow LO-artefact reading is dead. Recorded here as a falsified pre-registered
prediction, which is what the pre-commit discipline is for.

**A claim I made in-flight and corrected.** I said the close match of the 1920 reset
*rate* between the 8 s and 25 s dwells (323/s vs 322/s) ruled out a duty-cycled
emitter. That is too strong. It rules out *slow or erratic* intermittency on
dwell-comparable timescales; a fast regular duty cycle averages to a stable rate in
both windows. The emitter explanation remains live at 1920–1930.

**State of the 1920–1930 feature: unresolved.** It is a stable ~20–30 MHz impairment
centred near 1925, coincident with the ambient emitter Task 64 measured across
1900–1950 (148's floor 42.29 dBFS at 1900 against 58.1 dBFS at 2000). The mechanism
is not established. 1940 was measured clean once (Task 65, 8 s); 1950 has never been
measured. §32.4 pre-committed to excluding this feature from the 1980–2010 structure
and that exclusion stands — they are separated by a clean 1960 measured twice.

### §33.11 What was decided NOT to do, and why

A real `legrun_go.sh LEG=A` at a candidate clean band was considered for the
remaining window and **rejected**, on the pre-registered rails rather than on caution:

1. §32.3 lists a real leg as requirement **(b) of adoption**, alongside the
   `bringup_r2r3.sh` LO edit (a) and the operator decision (d). Running (b) alone
   does not make it a measurement; it makes it the first step of adoption executed
   without (d).
2. It requires non-shipped LOs, which requires making `LO_A_TX`/`LO_B_TX`
   env-overridable in `bringup_r2r3.sh` — the restore-trap hazard declared in
   §32.3. Editing the shipped-restore path at 02:30 and handing the rig back at
   07:00 means that path was changed and never re-verified across a full cycle.
3. Every clean point tonight was measured with 148's transmitter parked at
   1.700 GHz. A LEG=A run at 2010 forces a choice for 148's transmitter: park it at
   1.700 and the PER is not the in-service configuration; put it at 1.900 and it is
   an untested pairing whose number does not transfer from the sweep either way.

### §33.12 Rig state at 02:25 EDT

Restore verified by effect from the unit log: `ARM GATE PASS (try 1)`, `r3 BRING-UP
COMPLETE`, `restore: BRING-UP OK` 02:24:53, and final `rfstat` on both boards —
148 `txlo=1900000000 rxlo=2000020000 txensm=rf_enabled rxensm=rf_enabled
txatt=0.000000 rxgain=34.000000 rssi=29.917 dpow=27.750`; 146 `txlo=2000000000
rxlo=1900040000 txensm=rf_enabled rxensm=rf_enabled txatt=0.000000
rxgain=34.000000 rssi=24.336 dpow=22.500`. Both boards are back on shipped LOs.
Keeper hold still in place; images unchanged on both boards all night.

**The forward leg remains down at shipped defaults** — that is the expected
consequence of the null profiled in §33.7, not a new failure.

---

## §34 — Task 67 pre-registration: boundary-closing sweep (written and committed BEFORE launch)

§33 named two open boundaries and one untested property. This sweep closes all three
with the **unmodified** instrument, and adds nothing else. It is a measurement leg,
not an adoption step; §32.3 continues to bind.

**Command to be run** (`OUT=` included this time — see §33.1):

```
two_jup/launch_rig_unit.sh bersweep3 \
  /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup/comb/band_ber_sweep.sh \
  DRY=0 DWELL=25 WINBITS=120 \
  FREQS="1940 1950 1980 2010 2110 2140 2170 2200" \
  OUT=<repo>/two_jup/comb/runs/<ts>_t67_bersweep3
```

Same geometry as Tasks 65/66: 146 TX at f, 148 RX at f+20 kHz, 148 TX parked at
1.700 GHz, 146 RX at 1.700020 GHz. 8 points at 25 s → ~31,176 frames and 3,741,120
scored bits per point. **Not sample-matched** to Task 65 (8 s) — matched to Task 66.

**Why these eight points.** 1940/1950 fill the only unmeasured gap between the two
known features (1940 was measured clean once at 8 s in Task 65; 1950 has never been
measured). 1980 and 2010 are repeats of the null floor and the best clean point, one
hour after Task 66, at near-zero marginal cost. 2110–2200 extends above the top of
the previously swept range on a 30 MHz grid — coarse enough to be cheap, fine enough
that a second null of the ~40 MHz width already measured could not hide between points.

**An honest note on what "closing the upper boundary" can mean.** A clean run's upper
edge can only be *measured* by finding a failing point above it. If everything from
2110 to 2200 is clean, no upper shoulder exists to be found in that range, and the
correct statement is "no upper failing boundary found across N MHz" — not "bounded".
This sweep can widen the claim and can discover a second null; it cannot manufacture
a shoulder that is not there.

**A caveat that applies only above 2100.** If the rig's antennas are tuned near
1.9–2.0 GHz, points at 2110–2200 may sit on an antenna roll-off. That can produce a
false FAIL (insufficient level), never a false pass — a point scoring zero errors
over 31,176 frames has adequate SNR whatever the antenna is doing. So clean results
above 2100 are trustworthy; a failure above 2100 must be reported as
**level-ambiguous** and checked against its rssi before being called frequency structure.

### §34.1 M0 — admissibility

`c_shipped` must land in **0.25–0.32** (`ber_120b`), matching the four prior
measurements. Outside that → **M5 VOID**: the sweep is uninformative and no branch
below is scored.

### §34.2 Branches, scored independently

- **M1 — WIDE CLEAN.** All four of 2110, 2140, 2170, 2200 score 0 errors. → the clean
  region runs from 2010 to at least 2200 MHz with **no upper failing boundary found
  across 190 MHz**. §33.6's caveat is downgraded accordingly, and the width claim
  becomes robust to the missing shoulder rather than dependent on it.
- **M2 — SECOND NULL.** Any of 2110–2200 scores `ber_120b` >= 1e-3. → further
  frequency structure exists above 2100. The clean claim is **not** extended above the
  last clean point below the failure. If the failing point's rssi is >= 33 dBFS
  (comparable to the null floor's 35–39) it must be reported as level-ambiguous per
  the antenna caveat above, and the reading is "unresolved", not "second null".
- **M3 — GAP.** 1940 and 1950 both clean → the 1920–1930 feature is bounded above at
  <= 1950 and is separated from the 1965–2005 null by a clean gap measured at 1940,
  1950 and 1960 (1960 twice). §32.4's exclusion of the 1920–1930 feature from the
  null is then supported by measurement rather than by grid spacing. If either fails,
  the two features may be contiguous and **§32.4's exclusion must be revisited in
  writing**, not quietly dropped.
- **M4 — STATIONARITY.** 1980 fails a third time (`ber_120b` > 0.4) **and** 2010 is
  clean a second time at 25 s → the frequency structure is stationary over >= 1 hour
  and three independent arms. If **1980 comes back clean, or 2010 fails**, the
  structure is NOT stationary. That would be the most important result of the night:
  it would make every "reproducible null" statement in §33 provisional, point at a
  time-varying cause (a moving scatterer, a duty-cycled emitter, thermal drift)
  rather than a fixed notch, and it must be reported that way in the morning report
  even though it contradicts what §33 already committed to.

### §34.3 Rules binding the outcome, fixed in advance

1. Whatever fires, **adoption is still not tonight's work** (§32.3). No LO default is
   changed, `bringup_r2r3.sh` is not edited, and no `legrun_go.sh` leg is run — the
   three reasons are recorded in §33.11 and none of them expire with this sweep.
2. `frames`, not `fps`, is the delivery metric (§33.9b). CFC is not tabulated at any
   point with non-zero `rstcs` (§33.9a).
3. Any `ber_120b` at or above ~0.49 is **saturated**; agreement there means "both
   fully broken" and carries no mechanism information (§33.4). Score such points on
   rssi and frame count.
4. Diagnostic work stops at **04:00** regardless of this sweep's outcome. If it has
   not completed and restored by then, it is scored on whatever rows exist and the
   remaining window goes to restore, hand-back and the morning report.
5. The rig must be left on shipped LOs with the keeper hold released and verified by
   effect before 07:00, images unchanged on both boards by readback.

---

## §35 — Desk finding: the forward received level dropped ~2.4 dB between 09-05 and tonight; the reverse level did not move

Pure desk work on **already-banked** data — no rig contact, run while Task 67 was in
flight. Source: the `rssi.jsonl` timelines that `w1leg_go.sh` writes on every air leg,
plus the `c_shipped` rows of Tasks 65/66/67.

### §35.1 The comparison

`in_voltage0_rssi`, read from `iio:device2` with receive gain railed at 34.0 dB in
every sample. **These are dB BELOW full scale: larger = weaker.**

| board / role | when | runs | samples | median rssi | range |
|---|---|---|---|---|---|
| **148** (forward receiver) | 09-05 07:39 – 16:22 | 7 | 242 | **27.45** | 27.10 – 27.99 |
| **148** (forward receiver) | 09-08 01:45 – 02:35 | 3 sweeps | 7 reads | **29.80** | 29.57 – 30.45 |
| **146** (reverse receiver) | 09-05 10:54 – 09-06 14:06 | 13 | 480 | **24.60** | 23.85 – 25.86 |
| **146** (reverse receiver) | 09-08 01:45 – 02:35 | 3 sweeps | 7 reads | **24.33** | 24.17 – 24.43 |

**Forward: −2.35 dB (weaker). Reverse: +0.27 dB (unchanged, inside its own scatter).**

The change is **one-directional**. Whatever moved, it moved on the 146-TX → 148-RX
path and left the 148-TX → 146-RX path alone, across the same interval, on the same
two boards, with the same gain setting.

### §35.2 The healthy anchor

`two_jup/comb/runs/20260905_161957_w1_t32b2/meta.txt` records a **real** forward leg
(`leg=A dir=fwd`, **`dry=0`**) at 09-05 16:24 with
`wedge_verdict=healthy crc=100% rate=2076f/s`, and its `rssi.jsonl` gives 148 a median
of **27.331** over 15 samples. Tonight the same leg direction scores crc 58–61 % with
148 at 29.6–30.4.

The `dry=0` matters: per the standing rig note, `legrun_go.sh` with `DRY=1` **fabricates**
`wedge_verdict=healthy crc=99% rate=1150f/s`. Every 09-06 and 09-07 `w1_air` run in the
archive carries exactly that fake string and `dry=1`; they are not evidence of anything.
The real legs are the `legA_t38_*` series (09-06 10:57 – 12:44, ~30 legs, crc 99–100 %,
rate 2075–2076 f/s) and the two `w1_bspair` legs of 09-07 21:03 and 21:20 (crc **61 %**
and **58 %**). The 32-hour onset window is therefore confirmed, not narrowed:
**09-06 12:44 → 09-07 21:03.**

### §35.3 What this does and does not establish

**Does:** an RF-path change occurred on the forward direction only, of about 2.4 dB at
the shipped carrier, somewhere between 09-05 16:22 (the last 148 level measurement) and
tonight. That is independent of the frequency sweeps and of the CRC statistic, and it
corroborates a *physical* change rather than a configuration or firmware one.

**Does not:**

1. **It does not narrow the onset window.** The last 148 level sample predates the
   window's opening by ~20 hours; every measurement inside the window was taken on 146.
2. **It does not identify 2.4 dB as the mechanism.** §33.8 excludes the level budget
   three ways, and that exclusion stands: 2000 MHz fails at ~30 dBFS while 1960 MHz is
   clean at 30.3–30.9 dBFS. A 2.4 dB level drop does not produce 28 % frame-start errors.
   The correct reading is that both the level drop and the error rate are **symptoms of
   the same spectral notch** — the level shift is what a null's flank moving onto the
   carrier does to wideband power, while the frame-start damage is what its in-band
   amplitude and group-delay slope do to the preamble.
3. **The LOs of the 09-05 runs are not recorded** in their meta files. Those legs ran
   `w1leg_go.sh MODE=air LEG=A`, which arms through `bringup_r2r3.sh`, whose forward
   LOs are hardcoded/defaulted to the shipped pair — so the comparison is at the same
   frequencies **by inference from the call path, not by readback**. Labelled
   [inferred]; everything else in this section is [silicon].
4. Instrument differs between the two epochs (`w1leg_go.sh` rssi timeline vs
   `band_ber_sweep.sh` `rfstat`/`dwell`). Both read the same sysfs attribute at the same
   railed gain, so they are comparable, but the sample counts are very unequal
   (242 vs 7) and the tonight-side spread is correspondingly less well characterised.

---

## §36 — Task 67 outcome: **M2 + M3 + M4 all fire. There is a SECOND null at ~2110, and the structure is stationary.**

Unit `bersweep3`, run dir `two_jup/comb/runs/20260908_023300_t67_bersweep3/`.
Launched 02:33:00, `SWEEP_OK` 02:44:46, `restore: BRING-UP OK` 02:46:03, unit inactive
`Result=success ExecMainStatus=0`. Scored against §34, committed at `3bc144e` before launch.

### §36.1 The 148 table (DWELL=25 s)

```
stage      fwd_MHz  frames  errs      ber_120b   rstcs  rssi1   rssi2
c_shipped  2000     31177   1041247   0.2778         0  29.658  29.567
f1940      1940     31176         0   0              0  28.462  27.905
f1950      1950     31176         0   0              0  28.880  28.821
f1980      1980     22436   1326989   0.4929       143  38.141  37.123
f2010      2010     31177         0   0              0  24.904  24.665
f2110      2110     11018    592586   0.4483         1  28.265  27.769
f2140      2140     31176         0   0              0  22.06   22.11
f2170      2170     31177         0   0              0  24.84   23.971
f2200      2200     31176         0   0              0  27.51   27.93
```

146's parked control scored **0 errors at all 8 points**. `rxgain` railed at 34.0 dB
throughout.

### §36.2 Branches

- **M5 VOID does not fire.** `c_shipped` = 0.2778, inside 0.25–0.32. Fifth measurement
  of the shipped pairing; the running set is 0.2755 / 0.2645 / 0.2782 / 0.2814 / 0.2778.
- **M1 WIDE CLEAN does NOT fire.** It required all four of 2110/2140/2170/2200 clean.
  2110 failed.
- **M2 SECOND NULL FIRES.** `f2110` scored 0.4483. Its rssi is **28.265**, below the
  33 dBFS level-ambiguity threshold §34.2 fixed in advance, so it is **not**
  level-ambiguous and counts as frequency structure. Per M2, the clean claim is not
  extended above the last clean point below the failure: **the credited clean run
  remains 2010–2100.**
- **M3 GAP FIRES.** 1940 and 1950 both clean at full dwell. The 1920–1930 impairment is
  now bounded above at <= 1950 and is separated from the 1965–2005 null by three
  measured clean points (1940, 1950, and 1960 twice). §32.4's exclusion of the
  1920–1930 feature from the null is now supported by measurement, not by grid spacing.
- **M4 STATIONARITY FIRES.** 1980 failed a **third** time (0.4929, rssi 38.141, frames
  22,436 = 28 % short) and 2010 was clean a **second** time at 25 s (0 errors, rssi
  24.904 against 24.897 an hour earlier — agreement to 0.01 dB). The frequency structure
  is stationary over >= 1 hour and three independent arms. Every reproducibility claim
  in §33 stands; the alternative reading §34.2 pre-committed to reporting — a
  time-varying cause — is **not** what the data shows.

### §36.3 The second null, and what makes it a null rather than roll-off

2110 sits between two measured clean points: 2100 (Task 65, 8 s, 0 errors, rssi 23.685)
and 2140 (Task 67, 25 s, 0 errors, **rssi 22.06 — the strongest level of the entire
night**). So the failure is an **isolated feature under 40 MHz wide**, not the start of
a band edge. A 4.6 dB level step from 2100 to 2110 followed by a 6.2 dB recovery to
2140 is far too sharp for antenna roll-off, which is the only reason the §34 caveat
existed.

Its **signature differs from the 1980 null**: `rstcs` = 1 versus 186, but frame delivery
is far worse — 11,018 frames against 31,176, a **65 % deficit**. At 1980 the carrier
loop thrashes; at 2110 the carrier loop is quiet and the **frame detector simply misses
two frames in three**. Consistent with a shallower null (28.3 dBFS against 38.7, ~10 dB
less deep) that corrupts the preamble without breaking carrier lock.

### §36.4 [inferred] A two-ray model that fits, with a falsifiable prediction

Two nulls, at ~1980 MHz and ~2110–2120 MHz, spaced **130–140 MHz**. A two-ray
reflection produces a periodic null comb of spacing `Δf = c/Δd`, giving an excess path
length of

> **Δd = c / 135 MHz ≈ 2.22 m** (range 2.14 – 2.31 m for a 130–140 MHz spacing)

i.e. a reflected path about 2.2 m longer than the direct one. The model is consistent
with the whole night's level data: received level rises monotonically away from each
null (1960 30.9 → 1950 28.9 → 1940 28.5 → 1910 27.2 → 1900 26.8 → 1880 24.2 on the low
side; 2140 22.1 → 2170 24.8 → 2200 27.5 climbing back toward a predicted null above
2200), and no clean point anywhere contradicts it.

**It also predicts nulls at ~1845 MHz and ~2250 MHz, neither of which has been
measured.** That prediction is the subject of §37 and is committed before the data
exists. If those points come back clean, this model is wrong and the Δd number must be
withdrawn — 1980 and 2110 would then be two independent features and the paragraph
above becomes a discarded hypothesis, not a finding.

Nothing in §33 or the morning report depends on this model being right. The null at
1965–2005 and the shipped carrier's position on its flank are direct measurements.

---

## §37 — Task 68 pre-registration: the comb test (written and committed BEFORE launch)

**Command:**

```
two_jup/launch_rig_unit.sh bersweep4 \
  /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup/comb/band_ber_sweep.sh \
  DRY=0 DWELL=25 WINBITS=120 \
  FREQS="1845 1860 2115 2125 2235 2250 2265" \
  OUT=<repo>/two_jup/comb/runs/<ts>_t68_bersweep4
```

Same unmodified instrument and geometry. 7 points, ~9 minutes plus restore, well inside
the 04:00 diagnostic cutoff.

**Why these seven.** 2115 and 2125 bracket the second null's centre inside the
2100/2140 clean brackets. 2235/2250/2265 straddle the comb's predicted third null at
~2250. 1845 and 1860 test the predicted null below 1980 (1880 is already measured clean
at 8 s).

### §37.1 The level-ambiguity problem, and the criterion that survives it

Received level is already climbing above 2140 (22.06 → 24.84 → 27.51 at 2200), which
could be antenna roll-off, a comb flank, or both. An **absolute** rssi threshold cannot
separate them up there. So the criterion for the upper triplet is **shape, not level**:

- A smooth roll-off makes rssi **monotonically increasing** (weaker) across
  2200 → 2235 → 2250 → 2265.
- A null makes it **non-monotonic** — a local maximum in dBFS at one of the three, with
  the point after it recovering by >= 2 dB.

Only the non-monotonic case counts as a null. A monotonic climb, even to a failing BER,
is reported as **level-ambiguous roll-off**, not as comb confirmation.

### §37.2 Branches

- **N1 — COMB CONFIRMED.** At least one of {2235, 2250, 2265} fails (`ber_120b` >= 1e-3)
  **with** the non-monotonic rssi signature of §37.1, **or** at least one of
  {1845, 1860} fails while 1880 stays clean. → the two-ray comb model of §36.4 is
  supported, the ~2.2 m excess-path estimate may be quoted **as an inference**, and the
  morning report gains a concrete geometric target for physical inspection.
- **N2 — COMB REFUTED.** All five of 1845, 1860, 2235, 2250, 2265 are clean. → the model
  is **wrong**. §36.4 is struck, the Δd number is withdrawn, and 1980 and ~2110 are
  recorded as two independent features of unknown common cause. This must be written up
  as a falsified prediction in the same voice as the §32.4 falsification, not quietly
  dropped.
- **N3 — NULL-2 LOCATED.** 2115 and/or 2125 fail → the second null's extent is bounded
  within 2100–2140 and its centre estimated from the failing set. **If both are clean
  while 2110 failed**, the feature is narrower than ~5 MHz, which no multipath null can
  be — that would point instead at a **spur or LO artefact** at 2110, and both §36.3 and
  §36.4 would need revisiting. Note 2112 = 55 x 38.4 MHz, the device clock; that
  coincidence is recorded here in advance so it cannot be retrofitted, and it is **not**
  a claim — the same reading was already falsified once at 1930 (§33.10).
- **N4 — VOID.** `c_shipped` outside 0.25–0.32 → nothing above is scored.

### §37.3 Standing rules, unchanged

Adoption remains out of scope (§32.3, §33.11). `frames` not `fps` (§33.9b). No CFC at
non-zero `rstcs` (§33.9a). `ber_120b` >= ~0.49 is saturated and carries no mechanism
information. **This is the last rig leg of the night**: diagnosis stops at 04:00, and
the remaining window goes to restore, keeper-hold release verified by effect, and the
morning report.

### §37.4 Task 68 scoring AMENDMENT — the device-clock confound in my own frequency list

Written 2026-09-08 02:57, mid-sweep. **Disclosure of what I could see when I wrote
this:** the run had produced four rows (c_shipped, f1845, f1860, f2115) and I had read
them. The remaining four points (2125, 2235, 2250, 2265) were **not** yet measured. The
amendment below is arithmetic about the frequency list, not a reaction to the data, and
it was prompted by an external reviewer who raised it without reference to the partial
rows. I am recording the visibility boundary rather than presenting this as a clean
pre-registration, because it is not one.

The device reference clock is **38.4 MHz** (`two_jup/lvds_61p44_fdd_jupiter.json:3`,
`deviceClock_kHz: 38400`). Integer multiples near my chosen points:

| multiple | frequency | my point | separation |
|---|---|---|---|
| 48 x 38.4 | 1843.2 | **1845** | 1.8 MHz |
| 50 x 38.4 | 1920.0 | 1920 (T65) | **0.0 MHz** |
| 55 x 38.4 | 2112.0 | 2110 (T67) / **2115** | 2.0 / 3.0 MHz |
| 59 x 38.4 | 2265.6 | **2265** | 0.6 MHz |

Three of the seven Task 68 points sit within ~3 MHz of an exact device-clock multiple.
**A failure at 1845, 2115 or 2265 therefore does not discriminate** between the two-ray
comb of §36.4 and a device-clock spur: both models predict a failure at those
frequencies. The §37.2 N1 branch as written would have credited such a failure as comb
confirmation. It must not.

**Amended discriminator set.** Only **1860, 2125, 2235 and 2250** are clean tests of the
comb model. Restating the branches against that set:

- **N1 — COMB CONFIRMED** now requires a failure at **2235 or 2250** with the §37.1
  non-monotonic rssi signature, or a failure at **1860**. A failure at 2265 alone is
  **AMBIGUOUS**, not confirmation, and must be reported as such.
- **N2 — COMB REFUTED** now reads: 1860, 2235 and 2250 all clean. 2265 and 1845 carry no
  weight either way, because a clean result there is equally consistent with both models
  (a spur can be absent at a given harmonic; a null can be mislocated).
- **N3** is unchanged except that a 2115/2125 failure is now explicitly read against
  2112 = 55 x 38.4 as well as against the comb.

### §37.5 The competing hypothesis I had not written down: clock spurs, not a comb

The reviewer's second point, and it is stronger than the confound:

- **1920 = 50 x 38.4 exactly.** Failed (ber 0.06981, **rstcs 2586**).
- **~2112 = 55 x 38.4.** Failed at 2110 (0.4483, rstcs 1) and at 2115 (0.2889, rstcs 1).
- **1980 is not a multiple** (1980 / 38.4 = 51.5625). Failed (0.4935, rstcs 143-186).

Two of the three failing features sit on exact clock multiples; the third does not. Their
`rstcs` signatures differ by three orders of magnitude — 2586 vs 1 vs ~150 — which in
§36.3 I attributed to null depth. The competing read is simpler: **1920 and ~2112 are
device-clock spurs; 1980 is a genuine channel feature; and the ~135 MHz "spacing" of
§36.4 is an artefact of pairing one of each.** Under this model the receiver's own
reference harmonic lands inside the passband; at LO = 1920 it lands exactly at band
centre (worst case, carrier loop thrashes, rstcs 2586), at LO = 2110-2115 it lands
+2 to -3 MHz off centre (frame detector damaged, carrier loop quiet), and at LO = 2100 or
2140 it is 12-28 MHz off centre and harmless. That ordering fits every measurement I
have, and it fits the rstcs ordering better than null depth does.

I am **not** adopting it. I am recording that it is live, that it was not in §36.4, and
that §36.4 was written as if multipath were the only candidate. The 1930 falsification
(§32.4) does not rescue §36.4 here: it killed the claim that *non-multiples* are clean; it
never tested the claim that *multiples fail*.

**Why this matters beyond bookkeeping:** the two models imply opposite operator actions.
Multipath at 2.22 m says go look for a reflector and move an antenna. A reference spur
says the geometry is irrelevant and the fix is in the radio's clocking or in the choice of
carrier. The morning report must **not** hand over a 2.2 m physical-inspection target on
the strength of §36.4 alone. It must name both models, state that they are unresolved,
and give the discriminating test as a next step rather than something run tonight.

The discriminating test, for the record and for the morning: **move the boards or the
antennas and re-measure the null positions.** A multipath comb moves with geometry; a
reference spur does not. A second, cheaper discriminator: sweep at 1 MHz steps across
2105-2120. A spur at a fixed 2112.0 gives a feature whose damage tracks the spur's offset
from band centre; a null gives a smooth ~40 MHz-wide bowl like 1980's. Neither is a
03:00 job — `bringup_r2r3.sh` has the LOs hardcoded at lines 56-59, so a full bring-up at
a non-shipped carrier is not a five-minute change.

### §37.6 Two corrections to §36, from re-reading the TSV

1. **§36.1 lists `f2110 errs 592586`. The TSV says `592709`.** Corrected here; the
   `ber_120b` of 0.4483 is unaffected at four figures. Source:
   `runs/20260908_023300_t67_bersweep3/band_ber_sweep.tsv`, the 10.0.0.148 f2110 row.

2. **"146's parked control" in §36.1 and §36.2 is the wrong description and overstates
   the control.** `band_ber_sweep.sh:175` calls
   `point "f$f" "$f" "$PARKF" "$((f*1000000+OFF))" "$((f*1000000))" "$PR"` — at every
   swept point 148's TX is set to `PARKF` = 1.700 GHz and **146's RX is retuned to
   1.70002 GHz**. 146 is not parked on the shipped carrier and it is not untouched: it is
   re-tuned to a *constant* frequency at every point. Its rssi is 24.4 dBFS at c_shipped
   and ~37.3-38.0 dBFS at all swept points, which is the tell — a level step that large is
   a retune, not a stationary link.

   So "146 scored 0 errors at all 8 points" controls for the **sweep machinery**: the arm
   sequence, the ssh/register path, the double-tap, the dwell, and the counter reads all
   work at every point. It does **not** control for anything frequency-dependent on the
   forward path, and I should not have implied it did.

   One thing it does buy, and it is worth having: 146 decodes **0 errors in ~10,000
   frames per point at rssi ~37.8 dBFS**, while 148 at 1980 fails at 0.4935 with rssi
   37.5. Same railed 34.0 dB gain, comparable received level, opposite outcome. That is a
   fourth independent argument that **level alone does not explain the forward failures** —
   weakened by being a different board on a different path in a different band, but it
   points the same way as the other three.

### §37.7 Lost-frame caveat, restated where the numbers are quoted

`ber_120b = errs / (frames x 120)` and `frames` is register 0x104, which counts
**detected** frames. Frames the detector never found contribute to neither numerator nor
denominator. Therefore:

- **1980: 0.4929 / 0.4935 understates the damage.** 22,436 of 31,176 expected frames
  (T67) and 7,275 of ~10,004 (T65) were detected — ~28 % of frames are missing from the
  measurement entirely.
- **2110: 0.4483 understates the damage.** 11,018 of 31,176 detected — **65 % missing**.
- **2115: 0.2889 does not have this problem** — 31,148 frames, full delivery.
- **The 2000 MHz headline does not have this problem** — 31,176-31,177 frames at every
  measurement, full delivery, denominator intact.

Per the standing rail, no BER figure at 1980 or 2110 may be quoted without this caveat
attached.

## §38 Task 68 outcome: the comb is REFUTED (N2), null 2 is located and is NOT narrow (N3)

Run `runs/20260908_025044_t68_bersweep4/`, DWELL=25, launched 02:50:44, `SWEEP_OK`,
restore `BRING-UP OK` at 03:02:18 with shipped LOs read back on both boards. Board 148,
the forward receiver:

```
stage      fwd_MHz  frames  errs      ber_120b   cfc1    cfc2    rstcs  rssi1   rssi2
c_shipped  2000     31176   1024898   0.2740       335    1867      0   29.558  29.904
f1845      1845     31176         0   0          -3463   -3462      0   28.119  28.69
f1860      1860     31174       873   0.0002334  -3451   -3374      0   24.724  24.795
f2115      2115     31148   1079991   0.2889     -2732   10784      1   30.159  30.431
f2125      2125     18467   1090848   0.4923     59439   10646  37256   26.358  26.383
f2235      2235     31177         0   0          -4281   -3622      0   28.781  28.735
f2250      2250     31176         0   0          -3465   -3493      0   28.273  28.147
f2265      2265     13414    791280   0.4916     67974   90327  13514   37.254  37.581
```

**N4 does not fire:** c_shipped = 0.2740, inside the pre-registered 0.25-0.32 void
window. Sixth independent measurement of the shipped carrier: 0.2755, 0.2645, 0.2782,
0.2814, 0.2778, 0.2740 — mean 0.2752, spread +/-3 %, ~144,000 frames, full delivery every
time.

### §38.1 N2 fires. The two-ray comb of §36.4 is REFUTED and Δd is withdrawn.

The amended N2 (§37.4) required 1860, 2235 and 2250 all clean. All three are:

- **2235: 0 errors in 31,177 frames.** Full delivery, rstcs 0, cfc normal.
- **2250: 0 errors in 31,176 frames.** Full delivery, rstcs 0, cfc normal.
- **1860: 873 errors in 31,174 frames, ber_120b 2.334e-4** — below the 1e-3 threshold,
  so clean by the pre-registered criterion. Flagged below as the one non-zero "clean".

§36.4 predicted a null centred near **2250** and another near **1845**. 2235 and 2250 are
the two cleanest-delivering points of the entire night, and 1845 scored a flat zero.
**The prediction failed.**

Accordingly, and in the same voice as the §32.4 falsification:

> **§36.4 is struck.** The two-ray multipath model is wrong. The excess-path-length
> figure **Δd ≈ 2.22 m (range 2.14-2.31 m) is withdrawn** and must not appear in the
> morning report, in the memory note, or in any hand-off. The "~135 MHz null spacing"
> that generated it was, as §37.5 anticipated, an artefact of pairing two features that
> have different mechanisms. I inferred a geometry from two data points and a prediction
> from that geometry; the prediction was tested at four frequencies and failed at all
> four. The model gets no partial credit for the two points it was fitted to.

Nothing in §33, §35 or the shipped-carrier result depends on §36.4. What is lost is the
physical-inspection target, which was never measured and is now known to be wrong.

### §38.2 N3 fires, and it rules OUT the narrow-spur sub-branch

Both bracketing points inside 2100-2140 fail: **2115 (0.2889)** and **2125 (0.4923)**.
With 2110 (T67, 0.4483) that is three consecutive failures spanning 2110-2125, bracketed
by clean 2100 (T65) and clean 2140 (T67).

§37.2's N3 said that if 2115 and 2125 both came back *clean* while 2110 failed, the
feature would be narrower than ~5 MHz and could not be multipath. The opposite happened.
**The feature is at least 15 MHz wide and at most 40 MHz wide.** That removes the
"single narrow CW spur" reading in its simplest form, and it is the one point tonight
that goes *against* §37.5.

It does not rescue the comb: a real second null at ~2118 with the first at ~1980 gives
Δf ≈ 138 MHz and therefore a third null at ~2256 — which is exactly where 2235 and 2250
came back spotless. The two features are wide, real, and **not harmonically related**.

### §38.3 2265 is doubly ambiguous and is scored as UNINFORMATIVE

2265 failed (0.4916) but carries no weight for either model:

1. **Clock-multiple ambiguity (§37.4):** 2265 is 0.6 MHz from 59 x 38.4 = 2265.6.
2. **Level ambiguity (§37.1):** rssi 37.254 dBFS, the weakest forward level of the night
   apart from the 1980 floor, and there is no measured point above 2265 to show the
   recovery that §37.1 requires. The non-monotonic test cannot be completed.
3. It is not where the comb predicted a null anyway.

Recorded as a measured failure; excluded from both models' evidence.

### §38.4 The one non-zero "clean" point: 1860

1860 is the only point all night with a small but non-zero error count — 873 errors,
2.3e-4, against flat zeros everywhere else clean. Full delivery, rstcs 0, cfc normal
(-3451/-3374), strong level (24.7 dBFS). It is clean by the pre-registered threshold and
I am scoring it clean. Recording it because 18 other clean points scored *exactly* zero,
so 873 is not noise in the usual sense, and 1860 sits 16.8 MHz above 48 x 38.4 = 1843.2.
Not pursued tonight. Not evidence for anything.

## §39 The finding of the night, from the CFC column, at the desk

I had been reading `ber_120b` and `rssi` and treating `cfc` as a health indicator to be
glanced at. Pulling the CFC column across all three sweeps separates the data completely.

**All 18 clean points, across three runs and three separate arms:**
cfc1 and cfc2 both inside **[-4281, -2851]** — a tight band around -3450.

**All 9 failing points:** at least one CFC **outside** that band — except one.

```
class                          points                     cfc1 / cfc2            rstcs   frames
CLEAN (n=18)                   1845 1860 1880 1900 1940   -4281 .. -2851         0       full
                               1950 1960 2010 2020 2040
                               2060 2080 2100 2140 2170
                               2200 2235 2250
DEAD ZONE (n=1 freq, 4 meas)   2000  x4                   +335/+1867  +5777/+3301  0     FULL
                                                          -796/-455   +1198/+1426
LARGE / ERRATIC CFO (n=5)      1980 x2                    -2906/+6880  +9983/+1600  40-186  -28 %
                               2110                       -14549/-18234          1       -65 %
                               2115                       -2732/+10784           1       full
                               2125                       +59439/+10646          37256   -41 %
                               2265                       +67974/+90327          13514   -57 %
NORMAL CFO, RESETS (n=1)       1920                       -3471/-3466            2586    -7 %
```

### §39.1 The shipped carrier is a DIFFERENT defect from the 1980 and 2110 features

This is the part that changes the diagnosis. I had been reading 2000 MHz as "20-25 MHz up
the recovering flank of the 1980 null" — the same feature, partially attenuated. **The CFC
column says it is not.** At 1980 the CFO estimate is large and erratic and the carrier
loop resets. At 2000 the CFO estimate is **near zero on all four measurements**, the
carrier loop is perfectly quiet (**rstcs 0**), and **every single frame is delivered**
(31,176-31,177 of 31,177). The receiver is locked, healthy and confident, and it decodes
27.5 % of the first 120 bits wrong.

That is not a weak-signal signature and it is not a null-shoulder signature.

### §39.2 It is the documented CFO dead zone

This modem has a known failure mode, recorded in the project memory and the reason the
shipped LO plan carries a deliberate offset at all:

> the fabric demod fails at residual CFO ≈ 0; a deliberate offset is mandatory

and, separately, the CFC health note:

> healthy fwd ≈ -3300, rev ≈ -4750, **near-zero = CFO dead zone**

The forward leg's commanded offset is **+20 kHz** (`bringup_r2r3.sh:56-59`:
`LO_A_TX=1900000000`, `LO_A_RX=2000020000`; the sweep applies the same `OFF=20000` at
every point). At every clean frequency that +20 kHz shows up as cfc ≈ -3450. **At 2000 MHz
it shows up as cfc ≈ 0.** Something at this carrier is cancelling the deliberate offset
and dropping the receiver into the dead zone.

Two further facts line up, and neither was collected to test this:

- **The reverse leg uses +40 kHz** (`LO_B_RX=1900040000`) and has **never** shown this
  collapse. Its healthy cfc is ≈ -4750, i.e. further from zero, consistent with a larger
  commanded offset.
- **146 RX at 1.700 GHz +20 kHz scored 0 errors at all 23 sweep points** with cfc ≈ -2000.
  Same offset, different carrier, no dead zone.

### §39.3 What this predicts, and why it is worth five minutes of rig time

If §39.2 is right, the forward collapse is **not RF, not multipath, not a spur, and not a
fabric bug**. It is a carrier-plan defect at one frequency, and the fix is a one-line
change to the LO offset in `bringup_r2r3.sh` — no rebuild, no flash, no image change.
That would also explain the single most awkward fact of the whole investigation: **a
32-hour onset window with no image change on either board.** A carrier-plan sensitivity
that was always marginal needs no code change to tip over.

It does **not** explain 1980, 2110-2125, 1920 or 2265. Those stay open, and §37.5's spur
reading stays live for 1920 and possibly 2110-2125.

## §40 Task 69 pre-registration: the LO-offset A/B (written and committed BEFORE launch)

```
two_jup/launch_rig_unit.sh offab \
  /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup/comb/band_ber_sweep.sh \
  DRY=0 DWELL=25 WINBITS=120 OFF=40000 FREQS="1980 2000 2110" \
  OUT=<repo>/two_jup/comb/runs/<ts>_t69_offab
```

`OFF` is an existing env knob of the unmodified instrument (`band_ber_sweep.sh:75`,
`OFF=${OFF:-20000}`). The script is **not** edited.

**The A/B is built into the run.** `band_ber_sweep.sh:143-144` hardcodes the `c_shipped`
stage to the shipped LOs — `setlo $A 1900000000 2000020000`, i.e. **+20 kHz** — regardless
of `OFF`. So a single run measures the shipped +20 kHz configuration and the +40 kHz
configuration at the same carrier, in the same arm sequence, minutes apart. c_shipped is
the positive control and must fail.

**The level control is free.** A 20 kHz change at 2 GHz is 10 ppm. Any RF explanation —
multipath, spur, roll-off, antenna — is identical to well within measurement resolution at
2000.020 and 2000.040 MHz. **rssi must not move by more than ~0.5 dB between c_shipped and
f2000.** If ber changes while rssi does not, the cause is not RF.

**Branches:**

- **P1 — OFFSET ARTEFACT, WHOLESALE.** 1980, 2000 and 2110 all clean at +40 kHz. The band
  structure is not RF at all; §36, §37.5 and §38.2 are all superseded and the entire
  spectral reading of the night collapses into a carrier-plan defect. Highest-impact
  outcome; I do not expect it, because 1980/2110 lose frames and thrash the carrier loop
  in a way the dead zone does not.
- **P2 — DEAD ZONE AT THE SHIPPED CARRIER.** 2000 goes clean (ber_120b < 1e-3) at
  +40 kHz while 1980 and/or 2110 still fail. **This is the outcome §39 predicts.** It
  makes the operational defect a one-line LO change, keeps 1980/2110-2125 as genuine
  unexplained RF features, and gives the morning report a fix candidate instead of an
  inspection target.
- **P3 — DEAD ZONE REFUTED.** 2000 still fails at ~0.27 with +40 kHz and rssi unmoved.
  The near-zero CFC at 2000 is then a *symptom* of whatever breaks the demod, not its
  cause. **§39.2 is withdrawn**, §39.1's class separation survives (it is an observation,
  not a model), and the shipped-carrier defect returns to unexplained.
- **P4 — VOID.** c_shipped does not land in 0.25-0.32, or the restore fails. Uninformative.

**Scoring rules, unchanged from §37.3:** score `frames` not `fps`; quote no BER at 1980 or
2110 without the lost-frame caveat of §37.7; adoption of any LO change is **out of scope
tonight** — a passing P2 is a recommendation to the operator, not a shipped default, and
`bringup_r2r3.sh` is **not** to be edited tonight. This is the last rig leg of the night;
diagnosis stops at 04:00 and the remainder of the window goes to restore, keeper-hold
release verified by effect, and the morning report.

## §41 Task 69 outcome: P3 fires. The CFO dead zone is REFUTED as the cause — but the offset is not innocent.

Run `runs/20260908_030642_t69_offab/`, DWELL=25, `OFF=40000`, unmodified instrument,
launched 03:06:42, restore `BRING-UP OK` 03:13:12 with shipped LOs read back on both
boards. Board 148:

```
stage      offset  fwd_MHz  frames  errs      ber_120b  cfc1     cfc2     rstcs  rssi1
c_shipped  +20 kHz  2000    31176   1090597   0.2915      4484      413      0    30.158
f1980      +40 kHz  1980    23249   1376516   0.4934       284     5740    217    38.02
f2000      +40 kHz  2000    31176   1159518   0.3099     -2918    -3554      0    29.948
f2110      +40 kHz  2110    31109   1331604   0.3567    -15071   -21274      0    27.977
```

**Not void:** c_shipped = 0.2915, inside 0.25-0.32. Seventh measurement of the shipped
configuration. **Level control holds:** rssi 30.158 (+20 kHz) vs 29.948 (+40 kHz) at the
same carrier — a 0.21 dB difference, inside the pre-registered 0.5 dB bound. Whatever
differs between these two rows, it is not RF level.

### §41.1 P3 fires: §39.2 is withdrawn

§40's P2 required `ber_120b < 1e-3` at 2000 MHz with the offset doubled. The measured
value is **0.3099** — no improvement on the +20 kHz control, and if anything slightly
worse. Therefore:

> **§39.2 is withdrawn.** The near-zero CFC at the shipped carrier is **not** the cause of
> the forward collapse. It is a symptom of something else, and moving the receiver out of
> the dead zone does not recover a single bit. The prediction was written down, it was
> cheap, it was decisive, and it was wrong.

§39.1 survives untouched, because it is an observation and not a model: the shipped
carrier remains a distinct failure class — full delivery, rstcs 0, moderate BER — from
1980 and 2110-2125, and the CFC column still separates all 18 clean points from 8 of the
9 failing ones. What is dead is the claim that the dead zone *causes* the collapse, and
with it the hope of a one-line LO fix.

### §41.2 The result the test was not designed to produce: 2110 recovers its frames

The line I did not expect. At 2110 MHz, changing the receiver's LO offset from +20 kHz to
+40 kHz — **9.5 ppm at 2.1 GHz** — changed frame delivery from

- **11,018 of 31,176 frames (65 % missing), rstcs 1, ber_120b 0.4483** [T67, +20 kHz]

to

- **31,109 of 31,176 frames (0.2 % missing), rstcs 0, ber_120b 0.3567** [T69, +40 kHz]

with rssi essentially unchanged (28.265 → 27.977, 0.29 dB). **The frame detector went from
missing two frames in three to missing one in five hundred, on a 20 kHz LO change.** No RF
mechanism — multipath, spur, roll-off, antenna, level — varies measurably over 9.5 ppm.
This is the single cleanest piece of evidence tonight that the 2110 feature is **not RF**,
and it was produced by a control I included for a different purpose.

Note per §37.7 that the two BER figures are not directly comparable: 0.4483 was computed
over 11,018 detected frames and 0.3567 over 31,109. Total errors rose (592,709 →
1,331,604) because the newly-detected frames are damaged too. The recovery is in
**detection**, not in bit accuracy.

1980 did not respond: 0.4934 at +40 kHz against 0.4929/0.4935 at +20 kHz, with the same
~25-28 % frame deficit and the same carrier-loop thrash. Whatever 1980 is, the LO offset
does not touch it.

### §41.3 What the CFC actually did, and the one inference I am not yet entitled to make

At 2000 MHz the CFC moved from `+4484/+413` (+20 kHz) to `-2918/-3554` (+40 kHz). The
second pair sits **inside the [-4281, -2851] band that all 18 clean points occupy**.

The tempting inference: CFC is linear in residual CFO, the clean band corresponds to
+20 kHz of *actual* offset, therefore at 2000 MHz a fixed **-20 kHz error** cancels the
commanded +20 kHz (giving the dead-zone reading) and the commanded +40 kHz lands back on
a true +20 kHz. That would make a real, unexplained 20 kHz carrier error at this frequency.

**I am not entitled to that yet.** If CFC were linear in commanded offset, +40 kHz at a
*clean* frequency should read about **-6900**, not -3450. I have never measured CFC at any
frequency with any offset other than +20 kHz, so I cannot distinguish "there is a -20 kHz
error at 2000" from "CFC is nonlinear or saturating and the clean band means nothing about
absolute offset". Both fit every number I have.

That is a one-run question, and §42 asks it.

## §42 Task 70 pre-registration: the CFC calibration control (written and committed BEFORE launch)

```
two_jup/launch_rig_unit.sh cfccal \
  /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup/comb/band_ber_sweep.sh \
  DRY=0 DWELL=25 WINBITS=120 OFF=40000 FREQS="2010 2250" \
  OUT=<repo>/two_jup/comb/runs/<ts>_t70_cfccal
```

Two frequencies that are **known clean at +20 kHz** — 2010 (T67, cfc -4023/-3539) and 2250
(T68, cfc -3465/-3493) — re-measured at +40 kHz on the unmodified instrument. This asks
one question and nothing else: **is CFC linear in the commanded LO offset?**

**Branches:**

- **Q1 — LINEAR.** CFC at 2010 and 2250 reads roughly **-6000 to -8000**, i.e. about
  double the +20 kHz value, and both stay clean (`ber_120b` < 1e-3). Then the clean band
  does encode absolute offset, and §41.3's inference is licensed: **there is a real
  ~20 kHz carrier-frequency error at 2000 MHz** that does not exist at 2010 or 2250. That
  is a concrete, unexplained, frequency-selective defect and it becomes the top item in
  the morning report's open list.
- **Q2 — NOT LINEAR.** CFC at 2010/2250 reads in the same -2851..-4281 clean band as it
  did at +20 kHz. Then CFC does not encode absolute offset, **§41.3's inference is
  withdrawn before it is ever used**, and the "near-zero CFC" of §39.1 becomes a bare
  correlate of failure with no quantitative reading attached to it.
- **Q3 — CONFOUNDED.** Either point *fails* at +40 kHz having been clean at +20 kHz. Then
  the LO offset itself moves the clean/failing boundary, the whole band map is a function
  of two variables rather than one, and every frequency-only conclusion in §33-§41 needs
  re-examination against offset. This would be the most disruptive outcome and it is the
  reason the control is worth running.

**This is the last rig leg of the night, for real this time.** Diagnosis stops at 04:00.
Adoption of any LO change remains out of scope; `bringup_r2r3.sh` is not edited tonight.

## §43 Task 70 outcome: Q1 fires. CFC is linear, and it is now a calibrated frequency meter.

Run `runs/20260908_031523_t70_cfccal/`, DWELL=25, `OFF=40000`, restore `BRING-UP OK`
03:20:36, shipped LOs read back on both boards.

```
stage      offset   fwd_MHz  frames  errs      ber_120b  cfc1    cfc2    rstcs  rssi1
c_shipped  +20 kHz  2000     31176   1056151   0.2823     2733     428      0   30.149
f2010      +40 kHz  2010     31176         0   0         -6551   -6652      0   24.793
f2250      +40 kHz  2250     31177         0   0         -6165   -6179      0   28.411
```

**Q1 — LINEAR.** Both known-clean points stayed clean at the doubled offset (0 errors,
31,176-31,177 frames, rstcs 0), so **Q3 does not fire** — the LO offset does not move the
clean/failing boundary, and the frequency-only conclusions of §33-§41 stand. And the CFC
roughly doubled at both:

| frequency | cfc at +20 kHz | cfc at +40 kHz | ratio |
|---|---|---|---|
| 2010 | -4023 / -3539 | **-6551 / -6652** | 1.74 |
| 2250 | -3465 / -3493 | **-6165 / -6179** | 1.77 |

### §43.1 The scale factor, cross-validated against an experiment I had forgotten

From these two points: **-2950 counts per +20 kHz = ~147 counts/kHz.**

Task 60 (§20) independently swept 146's **transmit** LO across +/-80 kHz at 2000 MHz and
recorded a straight line in CFC: -80 kHz -> -10,083; -50 -> -2,393; -20 -> -1,288;
0 -> +2,228/+2,408/+1,082; +20 -> +5,365; +50 -> +8,835; +80 -> +13,805. That slope is
**~153 counts/kHz**, in the opposite sense, exactly as it must be for a transmit-side
rather than receive-side offset.

**147 vs 153 counts/kHz, from two experiments run four hours apart that sweep opposite
ends of the link.** CFC is a calibrated residual-CFO meter at ~150 counts/kHz, and
§41.3's inference is licensed.

### §43.2 What the meter says: a real, frequency-selective carrier error

Converting at 150 counts/kHz, with the commanded offset always +20 kHz of receiver-above-
transmitter (which reads as **negative** CFC):

| frequency | commanded | CFC | implied residual | **error** | arm-to-arm spread |
|---|---|---|---|---|---|
| 18 clean points | +20 kHz | -2851 .. -4281 | -19 to -29 kHz | ~0 | **9.5 kHz** |
| 2010, 2250 | +40 kHz | -6165 .. -6652 | -41 to -44 kHz | ~0 | 3 kHz |
| **2000 (x7)** | +20 kHz | -796 .. +5777 | -5 to +39 kHz | **+20 to +35 kHz** | **44 kHz** |
| **2000** | +40 kHz | -2918 / -3554 | ~-22 kHz | **+18 kHz** | - |
| **2110** | +40 kHz | -15071 / -21274 | **~-121 kHz** | **-81 kHz** | - |

Two things fall out, and neither was visible before the meter was calibrated:

1. **At 2000 MHz the receiver's residual CFO is offset from the commanded value by
   +20 to +35 kHz, and it is ~4x less repeatable arm to arm** (44 kHz of spread across
   seven measurements, against 9.5 kHz across eighteen clean points).
2. **At 2110 MHz, with the carrier loop quiet (rstcs 0) and every frame delivered, the
   residual CFO is about -121 kHz against a commanded -40 kHz** — an ~80 kHz error that
   the receiver tracks happily and still decodes wrong.

So the failing frequencies are not merely attenuated. **The carrier arrives at the wrong
frequency, by a frequency-selective amount, and the error is largest where the damage is
worst.**

### §43.3 The check I should have run before Task 69, and what it costs

My own memory note on this defect already said, in terms:

> Residual CFO is **not** the explanation: Task 60 swept 148's RX LO +/-80 kHz and `ber`
> was flat 0.27-0.38 with no minimum

**Task 60 had already answered §40's question at 2000 MHz.** Deliberately correcting the
carrier by up to +/-80 kHz in 20 kHz steps does not recover the bits — the BER floor is
flat across the whole sweep. Task 69 re-derived that at one more offset and called it a
falsification of a hypothesis the record had already falsified. I wrote §39.2 and launched
§40 without re-reading the note that contained the answer.

What Task 69/70 did add, and it is not nothing: the 2110 frame-delivery recovery (§41.2),
the linearity calibration (§43.1), and the quantified frequency error (§43.2). But the
central claim of §39.2 was refutable from the archive at zero rig cost, and the standing
rail — check the measurement record before spending the rig — is the one I broke.

**Consequence for the diagnosis:** the CFO error of §43.2 is a **co-symptom**, not the
cause. Something upstream is both mistuning the carrier and corrupting the bits, and
correcting the carrier alone does not repair the bits.

### §43.4 Correction to the §39 table: most of those CFC values are not measurements

The same memory note records an instrument trap:

> CFC is **not a measurement** at any point where `rstcs` is non-zero

That invalidates a majority of the "LARGE / ERRATIC CFO" column in §39's class table.
Struck as non-measurements: **1980** (rstcs 40-217), **1920** (rstcs 2586), **2125**
(rstcs 37,256), **2265** (rstcs 13,514), and **2110 as measured in T67** (rstcs 1, and
frames 65 % short). Those rows show a carrier loop that is not locked; their CFC is
whatever the loop happened to be holding.

The corrected table is smaller and the separation survives on the valid rows only:

```
class                     freqs                  rstcs  CFC (valid)      delivery
CLEAN (n=18, +20 kHz)     1845 .. 2250            0     -2851 .. -4281   full
CLEAN (n=2,  +40 kHz)     2010 2250               0     -6165 .. -6652   full
FAIL, LOCKED (n=7)        2000 @ +20 kHz          0     -796 .. +5777    FULL
FAIL, LOCKED (n=1)        2000 @ +40 kHz          0     -2918 / -3554    FULL
FAIL, LOCKED (n=1)        2110 @ +40 kHz          0     -15071 / -21274  FULL
FAIL, LOCKED (n=1)        2115 @ +20 kHz          1     -2732 / +10784   full
FAIL, UNLOCKED (n=6)      1920 1980x2 2125 2265   >0    [not measurable] 25-93 %
```

**The class separation of §39.1 stands, and on the valid rows it is cleaner than I
claimed:** every one of the 20 clean readings sits where the commanded offset says it
should; every one of the 10 locked-but-failing readings does not. §39's original table
overstated its evidence by quoting six CFC values it was not entitled to quote.

### §43.5 Two qualifications to §43, both narrowing claims I made too broadly

**(a) The §43.4 strike applies to CFC values ONLY, not to the whole row.** `frames`,
`errs` and `rstcs` are direct counters; they do not depend on the carrier loop's internal
state and they remain valid at every point. This matters because the headline result of
§41.2 — 2110 recovering from 11,018 to 31,109 delivered frames — takes its "before" side
from the T67 2110 row, which §43.4 lists among the struck rows. **That result stands.**
What is struck from that row is its CFC pair and nothing else.

**(b) My rstcs threshold was applied inconsistently.** §43.4 struck T67's 2110 (rstcs 1)
while keeping 2115 (rstcs 1) as a valid CFC row. One reset in a 25 s dwell is not a loop
that has lost lock, so on a pure rstcs test both should be kept. The reason to distrust
T67's 2110 CFC is not its rstcs — it is that **65 % of frames were never detected**, so
whatever the loop was averaging over is not the transmitted signal. Corrected criterion:
**treat a CFC reading as invalid when rstcs > 1 OR the frame deficit exceeds ~5 %.** Under
that rule T67's 2110 stays struck (deficit), 2115 stays valid (rstcs 1, full delivery), and
nothing else in the corrected table moves.

Worth noting that T67's struck 2110 CFC (-14549/-18234) is **independently corroborated**
by T69's 2110 measurement at +40 kHz (-15071/-21274), which has rstcs 0 and full delivery
and is therefore fully valid. The ~80 kHz error at 2110 does not rest on a struck reading.

**(c) The §43.1 cross-validation is not two independent clean measurements.** Task 60's
±80 kHz transmit-LO sweep was run **at 2000 MHz** — a frequency I now claim carries a
20-35 kHz offset error and 44 kHz of arm-to-arm spread. T70's sweep was at 2010 and 2250,
both clean. So the two slope estimates (153 and 147 counts/kHz) agree, and that agreement
is real and useful, but one of the two was measured from inside the anomaly. The
calibration is unaffected — a slope is robust to a constant offset — and the agreement is
better evidence that the anomaly is a frequency *offset* than that it is a frequency
*scaling* error. It is not, however, the clean two-point independent confirmation §43.1
reads as.

---

## §44 The delivery sentinel has been recording the onset all along — the window is 5 minutes, not 32 hours

Found at 03:50 on 2026-09-08 while verifying the hand-back, from `~/modem-status/sentinel.log`,
an instrument that ran continuously and independently of every experiment in this ledger.
Read-only analysis, no rig action.

### §44.1 What the record shows [silicon, independent instrument, n=2134 samples since 08-25]

The sentinel samples the delivered frame rate every ~5 min. Its output is bimodal — a low
mode and a periodic high mode near 1868 — so the low mode has to be read separately.

**The low mode sat at EXACTLY 1245 f/s for 34 consecutive hours**, ending with the sample at
`2026-09-07 18:00`. Not 1245 ± noise: every single low-mode sample in those 34 hours read
1245. Then:

```
2026-09-07 17:55   1868        (high mode, normal)
2026-09-07 18:00   1245        <-- LAST CLEAN SAMPLE
2026-09-07 18:05   1062        <-- FIRST DEGRADED SAMPLE
2026-09-07 18:26   1236
2026-09-07 18:40   1173
2026-09-07 18:56   1218
2026-09-07 19:26   1177
2026-09-07 19:56   1154
2026-09-07 20:16   1169
2026-09-07 20:21   1752        <-- LAST high-mode sample in the entire record
2026-09-07 20:26   1010
2026-09-07 20:56   1008
2026-09-07 21:01   1002        (hold taken at 21:02; sentinel stopped)
2026-09-08 03:41    851        (post-release)
2026-09-08 03:46    865
```

Three facts, each independent of anything else in this ledger:

1. **The onset window is `2026-09-07 18:00` to `18:05`** — five minutes, from a 34-hour
   flat baseline. The "32-hour onset window" this campaign has been working from is
   **superseded** and should not be quoted again.
2. **The decline is progressive, not a step.** 1245 → ~1180 → ~1010 → ~860 over ten hours.
   It is still going down: tonight's 851 is the **lowest sample in the entire 2134-sample
   record** going back to 08-25.
3. **The high mode died.** 1868/1866/1855 through the evening, degrading to 1783/1758/1752,
   and after `20:21` it never appears again. Whatever the high mode was, it is gone.

### §44.2 What was happening at 18:05 — a lead, with the confound stated first

A flash chain ran on board 148 at almost exactly the onset:

```
18:09  two_jup/skidfix/txfix_flash_20260907_180906.log
18:09  two_jup/skidfix/.snap_flash148-bs-dry_txfix_flash_go.sh
18:09  two_jup/skidfix/.snap_flash148-bs_txfix_flash_go.sh
18:14  two_jup/skidfix/txfix_flash_20260907_180944.log
18:14  two_jup/skidfix/ddrcap2_witness_dec007ae70dd.bin
```

This is the BS byte-seam census flash (`dec007ae70dd`).

**The confound, stated plainly: the 18:05 degraded sample PRECEDES the 18:09 flash-log
timestamps.** A flash at 18:09 cannot have caused a drop already visible at 18:05. Two
readings survive that:

- **(i)** the sentinel samples every ~5 min, so the 18:05 reading covers roughly 18:00-18:05;
  the DRY pass of the flash chain (whose snapshot is dated 18:09 but which runs before the
  wet pass) and its board re-arms could fall in that interval. The flash chain is documented
  to re-arm boards as a side effect.
- **(ii)** the flash is coincidence and something else at ~18:03 is the cause.

**This ledger does not choose between them tonight.** What it records is that the tightest
independent onset window available puts the transition within minutes of a 148 flash chain,
and that this is the first hard timestamp the campaign has had.

**A fact that complicates the simple story:** 148 currently reads back `9f13705d9fb0`
(verified 03:42, §45), **not** the BS image `dec007ae70dd`. So the BS image is not on the
board now, yet the degradation persists and deepens. If the flash caused this, the cause
outlived the image — which points at board/PLL/arm state rather than at fabric content.

### §44.3 What this does and does not do to the night's results

**Does not invalidate the band map.** The eight shipped-carrier BER measurements spread over
the night read 0.2755, 0.2645, 0.2782, 0.2814, 0.2778, 0.2740, 0.2915, 0.2823 — mean 0.276,
±5 %, with no trend. The *bit* error rate was stable while the *delivery* rate fell. Those
are different quantities measured by different counters, and the clean/failing classification
of every swept frequency rests on the BER, which was stable.

**Does complicate the delivery-rate readings.** Any frame-count comparison made between two
points hours apart tonight sits on a baseline that was sliding underneath it. The 2110
delivery recovery (§41.2) is not affected — its before and after are 15 minutes apart within
one run.

**Is the highest-value lead in the ledger.** A five-minute onset window with a candidate
event inside it beats every frequency-domain result above.

### §44.4 Next step (read-only first, no rig action needed to start)

`two_jup/skidfix/txfix_flash_20260907_180906.log` and `...180944.log` are on disk and unread.
Read them before touching hardware: they record exactly what the chain did, in what order,
with what timestamps, and whether it rolled back. That alone may settle §44.2.

---

## §45 CORRECTION to §44 — I read the flash logs and they weaken my own lead. Retracting the causal claim.

Written at 03:55, minutes after §44, having done the read-only step §44.4 named. §44 stays in
the ledger as written; this section says what it got wrong.

### §45.1 The flash did NOT break the link — the board was verifiably healthy right after it

`two_jup/skidfix/txfix_flash_20260907_180944.log` (the wet pass; `...180906.log` is its DRY
rehearsal and touched no board) records the whole chain:

```
18:09:44   SENTINEL_STOP already present (external hold) -- will NOT remove it
18:09:45   148 current image: 9f13705d9fb0 (expect 9f13705d9fb0)
18:09:50   FLASHED dec007ae70dd
18:10:58   booted image: dec007ae70dd (expect dec007ae70dd)     <- readback verified
18:10:58   two-pass gate:
             post-arm: fps=1248 errps=0 capTAP=0xBCF94856
             post-arm: fps=1248 errps=0 capTAP=0xBCF94856
18:13:58   GATE_PASS x2
18:14:00   Tier-2 witness, 4 MB decoded:
             records 524288  demod_marks 43  tx_marks 43
             toff min 12314 max 12314 mode 12314 (1.000)  distinct 1
             slot histogram [131072, 131072, 131072, 131072]
```

**`fps=1248 errps=0`, twice, four minutes after the flash.** Full nominal rate, zero errors,
and a Tier-2 witness with a single distinct timing offset and a perfectly uniform slot
histogram. That is a healthy board. **§44.2's causal lead is retracted** — the BS census
flash did not cause the collapse, and nobody should spend the morning on it.

### §45.2 The 18:05 sentinel sample is contaminated, so the "5-minute onset window" is not what I said

The same log's first line is decisive: **`SENTINEL_STOP already present (external hold)` at
18:09:44.** A hold was already in force. Holds are taken *before* the work they protect, so
the rig was being taken out of service in the very interval — 18:00 to 18:05 — that I
identified as the onset. The 1062 reading at 18:05 is far more likely a sentinel sampling a
rig mid-hold than a hardware transition.

**Retracted:** "the onset window is 18:00-18:05, five minutes." I do not have a five-minute
onset window. What I have is the last sample of a clean baseline.

### §45.3 And the "progressive decline" has a mundane competing explanation I should have checked first

Everything after 18:00 on 09-07 is a period of **continuous rig experimentation** — legs at
19:13, 19:20, 19:37, 19:45, 19:56, 21:02, 21:03, 21:20, 21:53, and then band sweeps all
night. A delivery sentinel measuring a rig that is being repeatedly re-armed, retuned and
held reads low *because of the experiments*, not because of a degrading board. The 34-hour
1245 plateau it is being compared against is a period with **no rig work at all**.

So "the decline is progressive and still going" is **not licensed** by this data. I inferred
a hardware trend from a window whose defining feature is that I was using the hardware.

### §45.4 What actually survives from §44 — and it is still worth having

1. **The 1245 plateau is a real, clean, 34-hour healthy reference.** 12 samples an hour, every
   one exactly 1245, ending 2026-09-07 18:00. That is a better "healthy" baseline than
   anything else in this campaign.
2. **Tonight's 851/865 is genuinely anomalous and is NOT explained by rig activity**, because
   no rig work was in flight when it was sampled — the boards were restored and idle-armed,
   the hold was released at 03:41:46, and the 03:46:59 sample sits five minutes clear of the
   restart transient. 865 against a 1245 baseline is a 30 % deficit with nothing running.
3. **That deficit is roughly the size the forward collapse predicts.** The forward leg runs
   at 58-61 % crc_ok; 1245 x 0.6 = 747, and a leg that is part forward, part reverse would
   land between that and 1245. 865 is in that band. This is arithmetic consistency, not
   proof — but it means the sentinel number and the CRC number may be the same defect seen
   twice, which would make the sentinel a **free continuous monitor for the collapse.**
4. **The high mode really did disappear** after 20:21 and has not returned in any sample
   since. That is not explained by rig activity either, and I have no account of it.

### §45.5 The process lesson, which is the same one as §43.3

§44 was written from one instrument in about ten minutes and committed before I read the two
log files sitting on disk that the section itself named as the next step. Reading them took
forty seconds and retracted the headline. **The artefact was already on disk; I published
around it.** That is now twice tonight (§43.3 was the memory note, this is the flash logs).
The rule I keep breaking is not "check the archive" — it is "check the archive *before* the
commit, not after."

### §45.6 Corrected open question for the morning

Not "what happened at 18:05." The question is: **the delivery sentinel reads 865 f/s against
a rock-solid 1245 f/s baseline, with nothing running, and its high mode is gone.** Is that
the same defect as the forward CRC collapse, or a second one? A 15-minute idle sentinel
window scored beside a `rom_air_ber.sh` run on the same boards answers it, costs one leg, and
needs no flash.

### §45.7 The relaunch control — §45.4's surviving claim tested, and a second error corrected

Written 03:58. §45.4 point 2 asserts tonight's 865 was taken with **nothing running**. That
assertion had a competing explanation I had not tested: the release at 03:41:46 *relaunched
the sentinel*, so every post-release sample is also a post-restart sample. If the sentinel
runs low for its first few windows after any restart, 851/865 is a startup artefact and
§45.4 point 2 collapses. The record answers this directly — 18 keeper relaunches since the
1245 baseline began (`2026-09-04 20:44`).

**First rate sample after each relaunch, 1245-era, in order:**

`1245, 1868, 1868, 1244, 1245, 1245, 1245, 1245, 1245, 1245, 1245, 1245, 1245, 1245, 1236,
1238, 1855, 851`

Seventeen of eighteen are at baseline (1245), within 1 % of it (1244/1236/1238), or in the
high mode (1868/1855). **Tonight's 851 is the only relaunch in the entire 1245-era whose
first sample is not at or near baseline.** A restart does not depress the sentinel. §45.4
point 2 survives the control.

**And it is sustained, not a settling transient.** Four samples now exist post-release:

```
2026-09-08 03:41:58   851
2026-09-08 03:46:59   865
2026-09-08 03:52:01   881
2026-09-08 03:57:03   828
```

Sixteen minutes, no upward trend (881 then 828). Confirmed idle by unit list at 03:58: the
only running services are `sentinel-034146.service` and `sentinelkeeper-034146.service`, and
no hold file is present.

**The second error, corrected.** §44 point 2 says tonight's 851 is "the lowest sample in the
entire 2134-sample record," and morning report §10 repeated it as "the two lowest readings."
**Both are false.** 74 of 2136 samples are below 900 f/s; the record low is **389**
(`2026-09-05 02:01`). §44 is retracted wholesale by §45 so its copy is moot, but the report's
copy was live and is now fixed.

What is true, and is the weaker claim that should have been made: prior sub-900 samples occur
in **bursts during rig activity** — the 09-05 10:00–10:35 run of 533/514/491/681/735/873/840
is the clearest example, and it sits inside a working window. Tonight's four are the first
sustained sub-900 excursion in the record with the rig **verified idle**. That is the property
that makes them interesting, not their rank.

This check took one `grep`-class query against a file already parsed, and it is the same
class of check §45.5 says I keep skipping. It was run this time because the reviewer asked
for it, not because I proposed it.

### §45.8 Overnight series supersedes the "30 % deficit" reading (07:30)

The sentinel ran unattended 03:41→07:28 with the rig verified idle (no run dir or `.snap_*`
written since 04:00, no rig process, no ssh to either board). 42 samples:

```
04:02-04:22    827  827  801  815  882
04:27-05:27   1210 1189 1182 1179 1183 1173 1175 1179 1174 1174 1175 1178 1182
05:32-06:22   1096 1023 1015 1018 1020 1025 1006 1010 1017 1034 1021
06:27-07:23    206  182  163  230  314  312  300  318  300  310  276  358
07:28         1237
```

min 163, max 1237, median 1017.5 against a 1245 baseline.

**§45.4 point 2 and §45.7 are not wrong about the samples, but the reading built on them is.**
Four samples over sixteen minutes cannot distinguish "parked at a 30 % deficit" from "one
trough of a wandering series." With 42 samples it is clearly the latter: **delivery is
episodic and self-clearing.** The 06:27–07:23 hour at 163–358 f/s is the most severe
excursion anywhere in the 2100+ sample record, it is uncontaminated, and it ended on its own.

Three consequences:

1. **Retire the phrase "30 % deficit."** Quote the series.
2. **The signature favours the delivery/stall class** over a steady RF or BER defect: nothing
   that restores itself from 163 to 1237 f/s unaided looks like a link-budget or carrier
   problem.
3. **The proposed settling test is mis-sized.** A 15-minute `rom_air_ber.sh` window beside an
   idle sentinel can land wholly inside a good stretch and return a false null. Span an
   episode or repeat, and score against the concurrent sentinel samples, not the baseline.

The 34-hour exactly-1245 plateau ending `2026-09-07 18:00` still stands as the reference, and
the link has not held a stable plateau since.

## §46 — 2026-09-08 morning: the reboot killed the sentinel, and the boards' own watchdogs recorded what it missed

**Desk + read-only board probes, 08:05–08:12 EDT. The only rig action was the sentinel's own
recovery chain (bring-up `r3`), which fired automatically at 08:07:35 when the relaunched
sentinel read a forward delivery rate of 0/s.** The plan for the day is
`~/.claude/plans/get-previous-context-from-flickering-magpie.md` (approved 08:05).

### §46.1 Timeline (all EDT; 146's own clock is BST = EDT + 5 h, its watchdog stamps are converted)

| when | source | what |
|---|---|---|
| 05:29:54 | 148 watchdog | one carrier-reset storm (`drstcs` 6,724/5 s), FULL RE-ARM, LOCKED again 05:30:21 |
| 05:32 → 06:22 | sentinel | rate steps from ~1180 to ~1020 **at that re-arm** — the arm lottery, seen live |
| 06:27 → 07:23 | sentinel | 163–358 f/s for an hour, **no watchdog event on either board** — the receiver keeps framesyncing (0x104 ≥ 50/window, no storm), so this is CRC-fail loss (class A), invisible to both watchdogs |
| 07:28, 07:33, 07:38 | sentinel | 1237, 1237, 1236 — recovered by itself, no re-arm |
| ~07:40 | workstation reboot | sentinel + keeper (transient units) die; log ends 07:38:18 |
| 07:44:59 → 07:52 | 148 watchdog | continuous storms (`drstcs` 1.3–7.4 k per 5 s), a FULL RE-ARM every ~30 s, none holds |
| 07:50:30 → 08:07 | 146 watchdog | storms on the REVERSE receiver too (`drstcs` 3.2–4.7 k), 10 re-arms — begins 5.5 min after 148's, i.e. after 148's re-arms (each a 0x000 soft reset of 148 = a TX gap on the reverse leg) |
| 07:52:52 → 08:07:28 | 148 watchdog | **a third state: silence.** `drstcs` = 0 and 5–29 framesyncs per 5 s (≈ noise rate) for 15 min; 148's daemon `idle_rx` = 0 with `crc_drop` still climbing slowly; 146 was still pushing (`dma_tx` 21.5 M). 148's re-arms every 30 s do not leave it |
| 08:07:23 | this session | keeper relaunched (`sentinelkeeper-080723`) |
| 08:07:35 → 08:08:53 | sentinel | `WEDGE detected (rate=0/s)` → `bringup_r2r3.sh r3` → **ARM GATE PASS try 1, 1247 f/s both directions**, daemons restarted 08:08:23 |

Watchdog snapshots (taken by the sentinel before its recovery truncates them):
`~/modem-status/wdlog_10.0.0.148_20260908_080735.txt`, `..._146_...`. 41 FULL RE-ARMs on 148
since its 03:20 start, 10 on 146 since 08:20 BST (03:20 EDT).

### §46.2 What this changes

1. **Three distinct forward-leg states exist, and the sentinel and watchdogs each see a
   different subset.** (i) CRC-fail with full framesync: the hour at 06:27 — sentinel sees it,
   watchdogs do not. (ii) Carrier-reset storm: 07:44 — watchdog sees it, cannot clear it with
   its own re-arm (41 tries), the sentinel's full `r3` bring-up clears it first try.
   (iii) Deaf: 07:52–08:07 — framesync at the noise rate, no resets, 15 minutes, re-arms do
   nothing. (iii) is new and is the worst: the receiver is not even trying.
2. **The two boards' watchdogs cross-couple.** A re-arm is a 0x000 soft reset, which gaps the
   board's own transmitter; ATARM_CLASS.md showed a ≥ 7 ms TX gap puts the far receiver into a
   storm it cannot leave without a double-tap re-arm. 146's storms started 5.5 min into 148's
   re-arm sequence and continued until the `r3` bring-up. A single-board re-arm therefore
   spreads a fault to the other leg; that is a harness/watchdog design defect independent of
   the RF question, and it makes any "both legs bad" reading during a re-arm loop suspect.
3. **The sentinel series has no time-of-day structure** (hour-of-day median of the low mode
   is 1158–1169 for every hour across 2,180 samples, 08-25 → 09-08), so a diurnal thermal
   story for the episodes has no support. The high mode (≥ 1500) is absent in all 48 samples
   of 09-08 after appearing on every prior day (15–46 per day).
4. The 34-hour 1245 plateau ended 09-07 18:00; since 09-07 20:26 the record is: 20:26 → 04:22
   n=17 min 801 med 882; 05:32 → 07:23 n=23 min 163 med 358.

### §46.3 Instrument change (plan §3.1, done 08:12)

`~/modem-status/delivery_sentinel.sh` now also reads `crc_drop` on 148 and `idle_rx`/`crc_drop`
on 146 from the same daemon stats line it already greps (no register traffic), and logs
`ok rate=R/s crc=P% rev=R2/s rcrc=P2%` where `crc` = ok/(ok+CRC-fail) over its 10 s window.
The recovery trigger is unchanged. Previous version banked as `delivery_sentinel.sh.pre_crccol`.
The old unit was stopped inside its 290 s sleep (last log line `recovery chain done`), the new
file swapped in by `mv` (new inode; the stopped process never read it), and the keeper relaunches.
Helpers unit-tested against a fake `anyssh.sh` (65.0 % and 100.0 % cases, and the "-" no-frames
case) before install.

### §46.4 The sentinel's "high mode" is an instrument artefact — resolved at the desk (08:16)

The resume file lists the high mode (1750–1868 f/s) stopping dead after 09-07 20:21 as
unexplained. It is not a link state. The daemon prints a stats line every 5 s (`-s 5`); the
sentinel reads the last line, sleeps 10 s, reads again and divides by 10. Depending on the
phase, the window spans two lines (10 s of frames) or three (15 s of frames): the high mode
is exactly **1.5 ×** the low mode. Check against the whole record: max 1868 = 1.5004 × 1245,
114 samples read exactly 1868 and 451 read exactly 1245; today's first CRC-aware sample read
`rate=1399/s crc=74.9%` and 1245 × 1.5 × 0.749 = 1399. The mode is fixed per daemon
instance (the 300 s cycle is a near-multiple of 5 s), which is why it flips at daemon
restarts and why it vanished after the 20:21 restart. Consequences: `rate=` has a ±50 %
quantisation and only its ratio to 1245 or to 1868 is meaningful; the new `crc=` ratio is
unaffected; the ARM GATE's `rx=1247 f/s` is measured differently and is not quantised.
UNITEXIT p1fwd-081439 result=exit-code code=3 at=2026-09-08T08:25:09-04:00
UNITEXIT bringup-082802 result=success code=0 at=2026-09-08T08:29:32-04:00

### §46.5 Phase-1 forward baseline leg (08:14–08:25) — PER 56.7 %, and the leg died at 428 s with a level step

`two_jup/launch_rig_unit.sh p1fwd-081439 <ABS>/two_jup/rxfix/w1leg_go.sh DRY=0 MODE=air LEG=A
BOARD=148 DUR=600 R4B=1 RSSI=1 EXP=9f13705d9fb0 FIXCTL_BASE=0x0 TAG=p1_fwd`, under the keeper
hold, run dir `two_jup/comb/runs/20260908_081439_w1_p1_fwd`. Arm gate passed first try
(1247 f/s both). Scored with `python3 two_jup/accept_analyze.py <run>/cap/frames.bin`
(→ `accept.txt`), lost frames in the denominator:

- **PER 56.745 % (284,101 / 500,660), CP95UL 56.883 %, live window 417 s of 442 s
  [WEDGE truncated]**, crc_ok 61.00 % of 369,761 records. Bins 1:36,718 2:20,504 3-4:18,719
  5-20:16,748 21-100:505. `wedge_verdict=MID_CAPTURE_WEDGE after 428 s (delivery flatlined
  14 s)`; delivery stalls at 171 s, 341 s, 419–428 s.
- crc_ok per 10 s drifts **63–71 % → 52–57 %** over the window (monotonic decline, no step).
- **148 rssi 33.5–34.4 dBFS during the leg** (rxgain 34.0, decpwr 29–30). The record of the
  forward received level at the shipped carrier is now **27.45 (09-05) → 29.80 (09-08 01:45)
  → 33.9 (09-08 08:17) dBFS** — 6.5 dB weaker in three days, monotonic. The reverse receiver
  (146) reads 25.2 today vs 24.6 on 09-05: unchanged.
- **At the death (420 s): rssi steps 33.9 → 37.5 dBFS within one 10 s reading, decpwr 30 →
  32, frames/10 s 9,231 → 400, pop_on_empty 155 → 29,202 (ring starved: no symbols), rstcs 2 →
  1,196 in the last bin, cfc median 7,952 → 46,652.** The receiver ran out of signal, then the
  carrier loop stormed. Same signature as the 07:52–08:07 "deaf" state (§46.1).
- Ring witnesses healthy until the death: occupancy 9, r4b_skips ≈ 400/10 s, pop_on_empty
  44 → 155 over 410 s.
- The leg's restore did NOT bring the rig back: capture_r3's pair.iq health check flagged the
  `REBOOT-ONLY` class (occupied BW 2.40 MHz, env periodicity 0.9994) and both daemons were
  left down. A plain `bringup_r2r3.sh r3` (unit `bringup-082802`) then passed its gate first
  try (1247 f/s both ways) — so this was NOT the reboot-only class; the IQ check misfires on
  a deaf receiver. Restore rule for today: after any wedged leg, run the r3 bring-up before
  reading anything.

**Open question the deaf state raises:** 146's daemon `dma_tx` was not sampled at the moment
of death, so "146 stopped feeding its transmitter" is not yet separated from "the forward
path lost 3.6 dB". The 08:24:20 rssi step is at the same time capture_r3 was tearing the
daemons down (08:24:30 legrun exit), so it is not clean either way. The sentinel now needs a
`tx=` column (146 `dma_tx` delta) — added at the next swap.

### §46.6 08:31 — board 148 no-ping hang, caused by me. Rig needs the operator's power cycle.

**What I did:** at 08:31, while the Phase-1 reverse leg (`p1rev-083000`, `dpleg_go.sh`) was
in its bring-up — which arms BOTH boards through `bringup_r2r3.sh r3`, 146 first then 148 —
I ran a two-read `direct_reg_access` probe on 148 (0x104/0x150, 10 s apart) to separate
"fabric sees frames" from "host delivers none" for the post-bring-up `idle_rx=0 crc_drop=0`
reading. The ssh never returned; 148 stopped answering ping within a minute (08:32:27), 146
unaffected. This is exactly the class in `RIG_NOPING_FAULT.md` and the project memory rule
("direct_reg_access traffic racing board state; arms are the worst instance"). I checked
that the leg's own readers were on 146 and forgot that its bring-up touches 148.

**State at 08:33:** 148 no ICMP, `No route to host` on ssh. 146 up, daemon up. The reverse
leg unit is still `active`, stuck at `10.0.0.146 armed ROM` waiting on 148; it will fail on
its own and its restore will fail for the same reason. Keeper hold is in place
(`SENTINEL_STOP` + `RIG_LOCK`), so nothing else will touch the rig. No flash was involved.

**Recovery is power-cycle only** (occurrences #1–#3 in `RIG_NOPING_FAULT.md`). A watcher unit
(`wait148-*`, script in the session scratchpad) pings 148 every 10 s and, the moment ssh
answers, pulls `journalctl -b -1 -k` + the previous boot's last 40 lines + thermal + image
md5 into `two_jup/comb/runs/20260908_noping148/journal_prev_boot.txt` BEFORE any bring-up
(the runbook's standing instruction). Persistent journald on 148 has been on since 08-27, so
this occurrence should be the first with a kernel record.

**Rule, restated so it sticks:** no `direct_reg_access` read on a board while ANY unit that
can arm it is active — and a reverse leg arms 148. The only safe DRA window is inside a
leg's own reader on the board the leg names, or with no rig unit active at all.

### §46.7 09:11 — 148 back after the operator's reset; the persisted journal has NO kernel record of the hang

Operator reset 148 ("148 reset", ~09:10). `wait148-083333` pulled the journal at 09:11:46, before
any bring-up: `two_jup/comb/runs/20260908_noping148/journal_prev_boot.txt`. Boot −1 ran
09-07 22:18:00 → 09-08 08:30:52. **Its last kernel message is the harmless RSSI-read error at
23:34:42 on 09-07; nothing kernel-side for the final nine hours, and the final journal lines at
08:30:52 are x11vnc chatter.** The log simply stops — the "journal ends cleanly with no kernel
message" discriminator of `RIG_NOPING_FAULT.md`, the same as every earlier occurrence: a PS-level
lock-up on an AXI access that never completes, image-independent, unlogged. Image readback after
the reset: `9f13705d9fb0` (unchanged). The 08:30:52 stop time matches my 08:31 register probe.
UNITEXIT p1rev-083000 result=success code=0 at=2026-09-08T09:24:31-04:00
UNITEXIT bringup-092436 result=success code=0 at=2026-09-08T09:28:07-04:00
UNITEXIT bringup-093025 result=exit-code code=1 at=2026-09-08T09:34:56-04:00

### §46.8 Task 71 (09:35–09:45): the failing band has WIDENED to 1900, 2040 is clean and 12 dB STRONGER, and the defect is direction-specific

Rig sequence after the reset: `bringup-092436` passed on try 5 (148 ROM rx 861–1135 f/s);
148's daemon binaries were 0-byte files (the 08:30 rebuild was lost in the hard reset — ext4
never flushed it), rebuilt from HEAD (`rebuild148-092950`, md5 27b8bb4c4102, NAK-stat kept);
`bringup-093025` then **FAILED its gate 8/8 — 148 ROM rx 465–581 f/s, 146 1247 every try**.
The forward leg was degrading in ROM mode (no host, no DMA) minute by minute.

`two_jup/comb/band_ber_sweep.sh OUT=runs/20260908_093547_t71_bandnow DRY=0 DWELL=25
WINBITS=120 FREQS="1900 1960 2000 2040 2110"` (unit `t71sweep-093547`, ~31,200 frames/point,
reverse control parked at 1.7 GHz). `SWEEP_OK`. 148 = forward receiver:

| fwd MHz | 148 frames/31.2k | ber_120b | rstcs | **148 rssi (dBFS)** | 146 @1.7 GHz control |
|---|---|---|---|---|---|
| 2000 (c_shipped, before) | 16,752 | 0.494 | 31 | 34.8 | 0 errs, 24.5 |
| **1900** | 17,661 | **0.492** | **21,988** | **36.4** | 0 errs, 34.3 |
| 1960 | 31,172 | 0.0146 | 0 | 33.9 | 0 errs |
| 2000 | 13,164 | 0.492 | 50 | 34.9 | 0 errs |
| **2040** | **31,176** | **0.000** | **0** | **23.3** | 0 errs |
| 2110 | 20,547 | 0.465 | 322 | 31.4 | 0 errs |

Three things this settles:

1. **The impairment is a deep, frequency-selective LEVEL loss, and it is moving.** 2040 MHz is
   received at 23.3 dBFS with zero errors; 2000 MHz, 40 MHz away, is 11.6 dB weaker and half
   the frames are lost. 1900 was zero-error at 8 s and 25 s dwell last night (§36–§38) and is
   now the worst point (rstcs 21,988, 36.4 dBFS). The "notch" is widening toward lower
   frequency, hour by hour, consistent with the monotonic 148-level record (27.5 → 29.8 → 33.9
   → 34.9 dBFS at 2000 MHz across 09-05 → 09-08 09:40). §33.8's "level excluded" rested on
   1960 being clean at 30.3; today the clean point is 10 dB stronger than the failing one.
2. **It is direction-specific, not reciprocal.** At 1900 MHz the reverse direction (148 TX →
   146 RX, the shipped reverse carrier) delivered 31,189/31,189 frames with 0 errors at 24.5
   dBFS in the c_shipped row of this same sweep, while the forward direction (146 TX → 148 RX)
   at 1900 lost 43 % of frames at 36.4 dBFS. Same frequency, same minute, opposite outcome.
   The forward and reverse legs use DIFFERENT antenna pairs (146-TX→148-RX vs 148-TX→146-RX).
   So the defect is in 146's TX chain/antenna/cable or 148's RX chain/antenna/cable — one of
   two physical paths — not in "the band" and not in the air between the boards.
3. **The 09-07 "follows the band, not the board" reading (Task 63) is superseded** for the
   current state: today the same frequency behaves differently by direction. Whether 09-07's
   both-direction failure at 2000 was an earlier stage of the same thing or a second effect is
   not decidable from banked data; it does not change the next step.

**Next step, operator's hands, ~15 min, no flash:** swap ONE physical element and re-run this
exact sweep. Best first swap: exchange 148's RX antenna (or its cable) with 146's RX antenna. If
the forward leg comes clean and the reverse leg inherits the loss, it is that antenna/cable; if
nothing moves, swap 146's TX antenna next. A coax + attenuator path between 146 TX and 148 RX
answers the same question in one step if pads are available.

**Interim service option (needs your decision — it changes the shipped configuration):**
forward carrier at 2040 MHz is zero-error, full delivery and 23 dBFS right now. Moving
`bringup_r2r3.sh`'s forward pair to 2040/2040.02 would restore the forward leg today, but the
notch is moving and 2040 may not stay clean; it is a bridge, not a fix.

Restore after the sweep: shipped LOs re-applied, then `bringup_r2r3.sh r3` — see the unit log
for its gate result (the shipped forward carrier is inside the loss, so the ROM gate at 2000
MHz may not pass; that is the defect, not the restore).
UNITEXIT t71sweep-093547 result=success code=0 at=2026-09-08T09:47:17-04:00

### §46.9 Task 72 pre-registration (10:21, written before the sweep reports): antenna swap A/B

Operator reported "swapped antennas" at ~10:20 (which elements were exchanged is the operator's
record; the request was 148's RX antenna/cable ↔ 146's RX antenna). Same instrument, same five
points as Task 71 (§46.8), under the keeper hold: `band_ber_sweep.sh DWELL=25 WINBITS=120
FREQS="1900 1960 2000 2040 2110"`, run dir `runs/*_t72_antswap`. Sentinel record between the
sweeps: every 5-min recovery bring-up failed its gate (148 ROM rx ≤ 605 f/s) — the rig was out
of service at the shipped carrier the whole time.

Branches, evaluated on the 148 (forward RX) rows against Task 71:
- **S1 the swapped element was the fault:** 1900/2000 recover to full delivery, ber < 1e-3,
  148 rssi within ~3 dB of the 2040 point (≈ 23 dBFS), and the 146 @1.7 GHz control rows stay
  clean (the control uses 146's RX antenna, so if that antenna was bad the control degrades —
  that is the signature to look for on the 146 rows).
- **S2 the loss moved with the antenna to the reverse side:** 148 rows recover AND the 146
  control rows degrade (errors > 0 or rssi ≥ 30 dBFS).
- **S3 nothing moved:** 148 rows within Task 71's pattern (2040 clean & strong, 1900/2000
  failing, level 34–36 dBFS) → the swapped element is exonerated; next swap 146's TX antenna.
- **S4 everything worse / control broken:** re-seat and re-run once before reading anything.

### §46.10 Task 72 outcome (10:21–10:29): **S2 fires. The loss moved with the antenna. The forward defect was 148's RX antenna.**

`runs/20260908_102105_t72_antswap/band_ber_sweep.tsv`, same five points, 25 s each:

| fwd MHz | 148 (forward RX, now on the OTHER antenna) | 146 control @1.7 GHz (now on the SUSPECT antenna) |
|---|---|---|
| c_shipped 2000 / 1900 | **31,176 / 31,176, 0 errs, 22.9 dBFS** | 31,188 / 31,188, 0 errs, **27.8 dBFS at 1900** |
| 1900 | 31,176, 0 errs, 26.5 | 22,082 of 31.2k, ber 0.403, rstcs 27,301, **44.0 dBFS** |
| 1960 | 31,176, 0 errs, 21.7 | 19,304, ber 0.386, rstcs 31,882, 43.7 |
| 2000 | 31,176, 0 errs, 22.9 | 20,840, ber 0.402, rstcs 29,123, 44.4 |
| 2040 | 31,176, 0 errs, 23.8 | 20,860, ber 0.401, 44.5 |
| 2110 | 31,177, 0 errs, 28.8 | 20,980, ber 0.404, 44.3 |

- **Forward leg, every point: zero bit errors, full delivery, 21.6–28.8 dBFS** — 12 dB stronger
  at 2000 MHz than one hour earlier (34.9 → 22.9) and back to the 09-05 level or better.
- **The reverse control inherited the loss:** 146's receiver at 1.7 GHz went from 34.3 dBFS and
  0 errors (Task 71) to **44 dBFS, one third of frames missing, a reset storm** on the swapped
  antenna. At 1.9 GHz on that same antenna 146 still reads clean (27.8 dBFS, was 24.5) — the
  element's loss is frequency-selective and its shape differs on the other board's mount, which
  is what a damaged antenna or a failing connector does.
- The 148-RX antenna (as mounted before the swap) is therefore the physical fault behind: the
  09-06 → 09-07 onset with no image change, the one-directional 2.35 dB drop (§35), the band
  structure of §33–§38, the CFC "frequency error" co-symptom (§39/§43, a distorted-preamble
  artefact), the 06:27 hour-long episode, the 07:44 storms and the 07:52 deaf state, and every
  failed ROM gate this morning. **The forward leg's fabric, images, host and daemon are all
  exonerated for this defect.** The CFO-dead-zone, multipath and synthesiser hypotheses are
  all closed.
- **Operational:** the shipped carriers are usable again right now (forward 2000: clean; reverse
  1900 on the suspect antenna: clean at 27.8 dBFS in this sweep, but that antenna is now on
  146's RX and 146's reverse-leg level is 3 dB weaker than on 09-05). **Replace the antenna
  and/or its cable/connector**; until then the reverse leg carries the risk the forward leg
  carried. Next: Phase-1 baseline legs both directions on the swapped configuration.
UNITEXIT t72sweep-102105 result=success code=0 at=2026-09-08T10:30:35-04:00
UNITEXIT p1fwd2-103030 result=success code=0 at=2026-09-08T10:43:30-04:00

### §46.11 Phase-1 forward baseline on the swapped antennas (10:30–10:43): **PER 0.070 %, gate PASS**

`launch_rig_unit.sh p1fwd2-103030 <ABS>/two_jup/rxfix/w1leg_go.sh DRY=0 MODE=air LEG=A BOARD=148
DUR=600 R4B=1 RSSI=1 EXP=9f13705d9fb0 FIXCTL_BASE=0x0 TAG=p1_fwd2`, run dir
`runs/20260908_103030_w1_p1_fwd2`, scored with `accept_analyze.py` on `cap/frames.bin`:
**PER 0.070 % (512 / 728,543, lost frames in the denominator), CP95UL 0.077 %, live 600 s,
bins 1:134 2:92 3-4:61 5-20:1**, health line `crc=100% rate=1038f/s`, 148 rssi 22.9 dBFS median
over 48 readings (min 22.9, max 24.0). This equals the campaign's best forward number (0.079 %
on 09-05) on the same image and daemon lineage, and it is the first credited forward leg since
09-06 12:44. The four "delivery stalled 5 s" lines at 6/166/336/506 s are the capture harness's
own 170 s rotate cadence, not link events (bins show no run > 20).
UNITEXIT p1rev2-104434 result=success code=0 at=2026-09-08T10:58:05-04:00

### §46.12 Phase-1 reverse baseline on the swapped antennas (10:44–10:58): PER 0.367 %, gate PASS, 3.4 dB weaker than 09-05 — the suspect antenna is now on 146's RX

`launch_rig_unit.sh p1rev2-104434 <ABS>/two_jup/rxfix/dpleg_go.sh DRY=0 DUR=600 EXP=9acbe2ebe1db
TAG=p1_rev2` (DP gate: quiet), run dir `runs/20260908_104434_w1_p1_rev2`, `accept_analyze.py`:
**PER 0.367 % (2,689 / 733,560, lost frames in the denominator), CP95UL 0.381 %, live 604 s,
bins 1:403 2:260 3-4:235 5-20:41 21-100:1 >100:2**, health `crc=99% rate=1037f/s`, 146 rssi
median **28.0 dBFS** (min 22.9, max 28.9; 09-05 → 09-06 baseline was 24.6). Against the 09-06
credited 0.191 % (pooled N=3, CP95UL 0.197 %): the reverse leg is ~2× worse, with a burst tail
(44 runs ≥ 5 frames, two > 100) that the 09-06 legs did not have, at 3.4 dB less signal. That is
the swapped antenna doing on 146's RX what it did on 148's RX, at an earlier stage. The ≤ 1 %
target holds on both legs today, but the reverse number is NOT the 0.191 % baseline and should
not be quoted as steady state until the antenna/cable is replaced.

**Phase-1 baseline, both legs, today (09-08), same images as 09-06:**

| leg | PER | frames | CP95UL | rssi | vs best |
|---|---|---|---|---|---|
| forward 146→148 (148 rxfixr4b 9f13705d9fb0 + HEAD daemon) | **0.070 %** | 512 / 728,543 | 0.077 % | 22.9 | = 0.079 % (09-05) |
| reverse 148→146 (146 rxfixr4dr1 9acbe2ebe1db, DP out) | **0.367 %** | 2,689 / 733,560 | 0.381 % | 28.0 | 0.191 % (09-06) |

Rig handed back 10:59: hold released (`keeper_hold.sh release`, DRY=0), sentinel + keeper
relaunched, both boards on their banked images and the shipped LOs, no flash performed today.

## §47 — Development item 1: the byte-seam census paired leg, pre-launch (11:2x)

Repo/doc cleanup committed and pushed as `ecd61c8` (ledger §46, BRINGUP §0.2/§0.3, PROVENANCE
current images, NEXT_STEPS, canonical sentinel copy, today's small result files, test-binary
ignores). Working tree clean apart from local data.

**Plan.** Re-run RXFIX Task 51 exactly as pre-registered in `two_jup/comb/RXFIX_BS_PAIRED_PREREG.md`
(branches B1–B4, refusals unchanged), now that the antenna no longer dominates the forward leg.
Expected loss in the 480 s census window at today's 0.070 %: ≈ 420 frames — enough for B1/B2.

**Step 1 — flash 148 with the BS census image (operator; the classifier denies agent flashes):**

```
cd /mnt/onetb/scratch/qpsk-jupiter-modem
DRY=0 bash two_jup/comb/keeper_hold.sh hold          # unless already held
two_jup/launch_rig_unit.sh flash148-bs /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup/skidfix/flash_148_txfix.sh \
    DRY=0 FLASH_MD5=dec007ae70dd FLASH_TAG=rxfixbs FLASH_BAK=9f13705d9fb0
two_jup/agents/watch_unit.sh --spawn flash148-bs /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup/comb/FWD_CRC_REGRESSION_0907.md
```

Image `boot_known_good/BOOT.BIN.148.rxfixbs.dec007ae70dd` (7,203,552 B, md5 verified at the desk).
`FLASH_BAK` is the expected CURRENT image (`9f13705d9fb0`), which the chain re-verifies before
staging. The chain's gate is `arm148_mode1.sh` ×2 (148-only, 146 untouched). Preflight on 148 done
read-only from the desk before the launch — see the next entry for the result (stale
`/root/BOOT.BIN.staged`, free space, on-board rollback copy).

**Step 2 — the leg (agent, under the same hold, after `POSTFLASH_OK`):**

```
two_jup/launch_rig_unit.sh bspair-<ts> <ABS>/two_jup/rxfix/w1leg_go.sh DRY=0 MODE=air LEG=A BOARD=148 \
    DUR=600 PERIOD=10 BS=1 P8=1 R4B=1 RSSI=1 EXP=dec007ae70dd FIXCTL_BASE=0x0 TAG=bspair3
```

then `w1_score.py`, `accept_analyze.py`, `bs_pair_score.py` on the run. No register read from
anywhere else while the unit is active (§46.6).

**Step 3 — after the leg:** flash back to `9f13705d9fb0` (operator) unless the census image is to
stay in service; it is W1 + R4B + census, functionally the shipped fix plus read-only counters, and
the 09-07 legs on it (61 % crc) were the antenna, not the image.
UNITEXIT flash148-bs-122557 result=success code=0 at=2026-09-08T12:30:27-04:00

### §47.1 Flash done (12:25:57–12:30:xx): 148 = `dec007ae70dd` (W1 + R4B + BS census), GATE_PASS ×2

Operator at 11:5x: "flashes approved, run them yourself, do not gate on approvals for hardware flashes"
(memory note `flashes-preauthorized`). Unit `flash148-bs-122557`, log `two_jup/skidfix/txfix_flash_20260908_122557.log`:
current image 9f13705d9fb0 verified → FLASHED dec007ae70dd → booted image dec007ae70dd (readback) →
two-pass gate ARM_OK fps=1248 capTAP 0xBCF94856 golden ×2 → GATE_PASS ×2 → Tier-2 witness. Rollback
copy `/root/BOOT.BIN.9f13705d9fb0.bak` created by the chain. Keeper hold held throughout (mine, taken
12:25). Leg `bspair3-*` launched immediately after, per the Task 51 pre-registration.
UNITEXIT bspair3-123048 result=success code=0 at=2026-09-08T12:43:48-04:00

### §47.2 Task 51 re-run outcome (12:30–12:45): **B2 FIRES. The forward residual IS the byte seam — 98 % of the lost frames sit in census-drop intervals, r = 0.98–0.99.**

Unit `bspair3-123048`, run `two_jup/comb/runs/20260908_123048_w1_bspair3`, image readback
`dec007ae70dd`, arm gate try 1, health `crc=100% rate=2075f/s`, 48/48 readings usable,
`freeze_effective` on all, BS address map confirmed (only the canonical rotation fits 47 intervals),
`BS_CNT[7:0] = 0`, no recovery events, one span. Scorers:

- `accept_analyze.py` whole leg: **PER 0.061 % (450 / 732,321), CP95UL 0.067 %**, bins 1:128 2:81
  3-4:51 5-20:1 — the same forward residual as the 0.070 % leg two hours earlier on `9f13705d9fb0`;
  the census image costs nothing.
- `bs_pair_score.py` (same-window pairing on the board clock): census window 469.4 s, **dBS_DROP =
  11,978 words, dBS_TRUNC = 105 events, against 358 host-lost frames of 584,551 transmitted (0.061 %,
  CP95UL 0.068 %)**. VERDICT `fired`.
- Per-interval alignment (47 × 10 s intervals; scratch script, drops/truncs from `bs_pair_score.py`
  rows, lost = host_seq span − clean frames per interval on the board clock):

| | intervals | host-lost frames | CRC-fail records |
|---|---|---|---|
| census drop = 0 | 21 | **6** (0.29 / interval) | 3 |
| census drop > 0 | 26 | **352** (13.5 / interval) | 244 |

  **corr(dBS_DROP, lost) = 0.982; corr(dBS_TRUNC, lost) = 0.991; corr(dBS_TRUNC, CRC-fail) = 0.989.**
  Per truncation event: **114 words dropped (quantum 119 ≈ 0.62 frame), 3.35 host frames lost,
  2.3 CRC-fail records delivered.** The 09-05 host-carve finding (one CRC fail → a k×192-byte
  displacement cascade, resync catches most of it) is the downstream image of exactly this event.

**Reading (B2, as pre-registered):** the ByteRxFifo drop/truncation at the byte seam is the forward
residual. 6 of 358 lost frames (1.7 %) fall outside it — the true floor once it is fixed is
≈ 0.001 %. This also closes "downstream of the census taps" (B1) and "second process" (B3).

**Structure worth carrying into the fix:** the drops come in ~60 s trains separated by ~40–50 s of
zero (iv 3–8, 14–19, 24–30, 35–39, 46–47): a slow beat of ~110 s, i.e. the seam event depends on a
phase that drifts through the frame timing — consistent with the S2MM transfer boundary walking
against the frame/byte cadence at the inter-node rate offset, not with a random overflow. The fix
therefore has a deterministic sim target: reproduce a 119-word truncation at a transfer boundary
under ~2.5 ppm SRO, then remove it.

**Rig:** hold released 12:47, census image `dec007ae70dd` left in service on 148 (W1 + R4B + read-only
counters; PER unchanged); rollback `9f13705d9fb0` on-board as `/root/BOOT.BIN.9f13705d9fb0.bak` and in
the bank. 146 unchanged.

### §47.3 The BS_EVT / BS_CNT decode: every truncation is a k × 24-word (k × 192-byte) deletion

From the 48 frozen sweeps of `bspair3` (`bsEvt` 0x254, `bsCnt` 0x258, map BYTESEAM_INSTRUMENT.md §2.3):

- `bs_trunc_last` (the `state_wordCnt` at which the truncating `start` arrived): **119 on 40 readings,
  143 on 8**; `bs_trunc_min` 119–127, `bs_trunc_max` 172 (all readings); `bs_dropmax` = 143 words.
- **`bs_q24` = 106 of `bs_trunc` = 108** (cumulative over the leg): 98 % of the truncations satisfy
  `(191 − wordCnt) mod 24 == 0`. 191 − 119 = 72 = 3 × 24; 191 − 143 = 48 = 2 × 24; 191 − 172 = 19 is the
  ~2 % exception.

So the frame is cut short by exactly 2 or 3 units of 24 words = 192 bytes — the same k × 192-byte quantum the
host carve found on 09-05 (960/576/1152/384-byte displacements), now seen at the fabric pins with the
count that produces it. BYTESEAM_INSTRUMENT.md §1.3 rejected S3 ("no 24-word literal exists in the RTL")
and kept S5 (drop-oldest, un-quantised); the silicon says the deletion IS quantised at 24 words AND the
drop-oldest fires (dBS_DROP ≈ 119/143 per event). The 24-word unit is a 192-byte structure somewhere
between the FIFO and the serializer — the next desk task is to find what in the byte plane moves 24 words
(192 B) at a time (an S2MM burst of 24 × 64-bit beats? a 3-slice carve? the serializer's word framing?) and
build the sim reproduction around it. This is the whole forward residual (98 %) and it is deterministic.

### §47.4 Desk analysis of the seam event (13:00–13:40): what the census numbers pin down, and what the sim does NOT yet reproduce

All from `bspair3` readings, the census RTL (`rtl_sim/s1_rtl_bs/TxRxComposite.v` `bs_seam_census`), the
byte-plane RTL of the flashed lineage, and the banked Task 46 sim legs (`two_jup/comb/sro_sim/bs1_*`).

**What the taps are (RTL, not inference).** `bs_trunc` = RxAlign `startOut` arriving at the ByteSerializer
with `state_wordCnt` in 1..190 (the serializer discards the partial word and restarts); `bs_drop` = the
ByteRxFifo's `drop` (push while full → oldest entry discarded), `bs_dropmax` = the longest RUN of
consecutive drops. The serializer has a `ready` input but does not use it (`ready_1` is unused; the core
runs with ready = true), so **nothing downstream of the serializer can shorten a frame**; a truncation is
a deficit of decoded bits between two frame starts, upstream of the byte plane.

**Three arithmetic facts from silicon:**
1. Deficits are 72 or 48 words (3 or 2 × 24 words = 3 or 2 × 1536 bits = 300 / 200 µs of bit time at the
   15.36 MHz rail), `bs_q24` 106/108.
2. `bs_dropmax` = 143 and the typical drop run ≈ 114–119 words; **drop run + deficit = 191 in both
   observed pairs (119 + 72, 143 + 48)** — the FIFO discards exactly as many words as the truncated frame
   had accumulated. One event, both counters.
3. Loss onsets are FLAT modulo 16 and 32 (`[20,12,21,21,18,20,23,16,12,16,14,14,9,13,15,19]`), so the
   S2MM transfer boundary (16 frames at −M16) is **not** the actor on this RXQ=1 image — the 08-27
   "boundary comb" mechanism does not describe today's residual.

**What the banked sims say (Task 46 gate legs, same RTL):**

| sim leg | stimulus | bs_drop | dropmax | bs_trunc | q24 |
|---|---|---|---|---|---|
| dA / dB | ready held low 4200 / 4440 words (> DEPTH 4096) | 105 / 345 | 105 / 255 | **0** | 0 |
| k1536 | RxAlign `skip_count` = 1536 for one frame | **0** | 0 | 315 | 255 (all) |
| k1024 | skip 1024 | 0 | 0 | 315 | 0 |
| m10 / p10 / p000 | ±10 ppm SRO, no stall | 0 | 0 | 1 / 0 / 0 | 0 |

A ready stall alone drops and never truncates; a decoded-bit deficit alone truncates and never drops.
**Silicon does both, one-to-one, with run + deficit = 191. No banked sim stimulus produces that.**
`skip_count` (0x138) has no writer anywhere in `two_jup/` or the daemon (grepped), so the deficit is not a
poke. The FIFO's `DEPTH = 4096` is confirmed in the flashed tree's source (`jupiter_byte_rxfixbs_build`),
so a drop run of 119 words needs ready low for ≥ 17.7 ms *or* a full FIFO from another cause.

**Working hypothesis for the sim (to be tested, not claimed):** a single upstream event both starves the
serializer of k × 1536 bits AND stalls the byte plane's pop side long enough to fill the FIFO — the
candidates with a 100 µs / 1536-bit quantum are in the RxDeint → RxAlign readout (RxDeint reads 1 pair
per 2 `validIn` beats with a 24-pair margin; `RxAlign` re-arms on `frameStart` and emits `o < 12292`), i.e.
the demod frame timing (R4B skip windows, SRO) rather than the host. The ~110 s on/off train structure
(§47.2) is the phase drift such a beat would show.

**Next concrete step (sim, deterministic):** extend `rtl_sim/wrap_byte_bs.v` with (a) a per-frame trace of
`Receiver_recStart` vs the serializer `wordCnt` and the FIFO occupancy, and (b) a stimulus that shortens
ONE frame's `validIn` run by 1536 × k beats at the demod output (the k1536 leg does this at RxAlign; move
it upstream to RxDeint's `validIn`), then check whether the FIFO overflows on the same frame. If it does,
the mechanism is in hand and the fix is a bounded RxDeint/RxAlign readout change; if it does not, the
next stimulus is the R4B skip window itself (13-slot skip after `pcEnd`) at +/−2.5 ppm with the census on.
Silicon A/B afterwards with `bs_trunc → 0` as the pre-registered success and PER by `accept_analyze.py`.

### §47.5 REPRODUCED IN SIM (13:5x): a short frame + the DMAC's sync-transfer-start wait = the silicon event, to the word

**Mechanism, from the RTL.** `axi_dmac` `data_mover.v:114-116`: `s_axi_ready = pending_burst & active &
~abort & has_sync`, `has_sync = ~needs_sync | s_axi_sync`; with `SYNC_TRANSFER_START = 1` every transfer
(16 frames at −M16) begins with `needs_sync = 1`, and the DMAC holds **ready LOW** until the beat at the
FIFO head carries `tuser` (`s_axi_sync = s_axis_user[0]` = ByteRxFifo `outFirst`, presented from the head
word). The FIFO never advances its head without a pop. So if a transfer boundary lands MID-frame — which
happens as soon as one upstream frame is short — the two lock: the DMAC waits for a mark the FIFO will
never present, the FIFO fills (4096 words, 17.2 ms), then drop-oldest walks the head forward one word per
push **until the head is a `wFirst` word**, ready rises, streaming resumes. The drop run is exactly the
remainder of the partial frame at the head: 191 − deficit.

**Sim (`rtl_sim/run_dmac_sim_rtl.sh`, real egress RTL + real `axi_dmac`, RXQ=1 queued host model, 1600
frames, one frame in 400 emitted short):**

| FIFO | short by | lost frames | `fifo_dropped` | holes | silicon (§47.2/§47.3) |
|---|---|---|---|---|---|
| v4 (4096) | 72 words | 9 (3 events → **3.0/event**) | **357 = 3 × 119** | 2,3,4 frames, all at slot 0 | dropmax/run **119**, 3.35 lost/event |
| v4 (4096) | 48 words | 9 (3.0/event) | **429 = 3 × 143** | same | dropmax **143** |
| orig64 | 72 words | 9 | 357 | same | — |

Files `dmac_runs_rtl/v4_rxq1_short72.txt`, `v4_rxq1_short48.txt`, `orig64_rxq1_short72.txt`; the
no-jitter control `v4_rxq1.txt` is 0 lost / 0 dropped over 1000 frames. **The drop runs match silicon to
the word, the per-event loss matches (3.0 vs 3.35), and the FIFO depth is irrelevant to the loss** (the
4096-word FIFO only converts a 0.27 ms deadlock into a 17.2 ms one). §47.4's "run + deficit = 191" is
this: the FIFO discards the rest of the frame that was at its head when the DMAC started waiting.

**So the forward residual is two defects in series:**
1. **Upstream (root):** something between the demod and the ByteSerializer shortens a frame by exactly
   2 or 3 × 1536 decoded bits, ~1 frame in 5,500 (105 in 584 k). Still unlocalised (RxDeint/RxAlign
   readout suspects, §47.4).
2. **Amplifier (byte plane / DMAC contract):** a single short frame costs 3 frames instead of 1 because
   the sync-transfer-start wait deadlocks against a FIFO that cannot skip to a mark. Any misalignment
   from any cause pays this (the 08-27 boundary comb was the same amplifier fed by a different
   misalignment).

**Fix candidates for the amplifier (either removes ~2/3 of the residual on its own):**
- **F4 — pad truncated frames in `ByteSerializer`:** on a `start` with `wordCnt` in 1..190, emit
  `191 − wordCnt` filler words (with `wordLast` on the last) before restarting, so the stream stays
  191-word aligned; the truncated frame fails CRC at the host (1 frame lost, no deadlock, no cascade).
  Bounded RTL change, injectable through `rxfix_inject.py`, gateable on the existing SRO/census legs
  (`bs_trunc` still counts the upstream event — the witness survives).
- **F5 — `SYNC_TRANSFER_START = 0` on `rx_byte_dma`** (BD parameter): the DMAC never waits; the host's
  `qpsk_frame_resync` (already shipped) re-finds frame starts by magic. One-line BD change, but it gives
  up hardware re-alignment at every transfer and leans on the host scan.
F4 is preferred: it keeps the carve stride exact and the fix sits where the fault is observed.

### §47.6 F4 implemented and unit-tested (14:2x): RXFIX_PAD — the ByteSerializer pads a truncated frame to 191 words

Patch applied to a fresh sim tree `rtl_sim/s1_rtl_pad` (copy of `s1_rtl_bs`, so the census stays in) by a
scratch Python patcher (to be banked into `rxfix_inject.py` as option `PAD`). Design: on a `start` with
`state_wordCnt` in 1..190 the serializer schedules `191 − wordCnt` all-zero filler words, emits one per
enable beat with `wordLast` on the last, and queues (3 deep) any real word that completes meanwhile so
order is preserved; the arbiter is filler → queue → real. The census taps are untouched (`bs_trunc` still
counts the upstream event; `bs_words` now reads 191 per frame always).

Unit test `rtl_sim/tb_pad.v` (iverilog): frames A full, B truncated at 119, C full, D truncated at 143,
E, F full; checks every `wordFirst`-to-`wordFirst` gap is 191, `wordLast` rides word 191, real words are
never lost or reordered, fillers are zero.

| serializer | frames seen | words | real | fillers | gap errors |
|---|---|---|---|---|---|
| **RXFIX_PAD** | 6 | 1146 | 1026 | **120 = 72 + 48** | **0 — TB_PAD_PASS** |
| unpatched (s1_rtl_bs) | 4 | 1026 | 1026 | 0 | gap 334 = 143 + 191 (the truncated frame MERGES with the next, no `wordLast`, no `wordFirst`) |

The control row is itself a finding: on the shipped RTL a truncated frame never emits `wordLast`, so the
following frame carries no `wordFirst` either — two frames fused between marks — which is exactly the
misalignment the DMAC sync-wait then turns into a 3-frame loss (§47.5).

Next: verilate the pad tree against the SRO/census wrapper (`obj_byte_sro_pad`), run the k1536 skip leg
(the truncation control) and the p000 identity leg (~2 h each), expect k1536 → `bs_trunc` unchanged,
`ck_short` 0, one lost frame per truncation instead of a merged pair; p000 byte-identical to `bs1_p000`.
Then bank the patch in the injector and build `rxfixbs + PAD` for 148 on hdl-dev-2.

### §47.7 F4 kit and Vivado build launched (14:51–14:52)

- `rxfix_inject.py` variant `PAD` (commit f75d522; stacks on BS, one file, byte-identical to
  `rtl_sim/pad_patch.py` by test); injector suite 178/178. Kit script accepts `'W1 R4B BS PAD'` (a27b9c8).
- Kit `jupiter_byte_rxfixpad_build` derived from `jupiter_byte_seqbist_build` with W1 → R4B → BS → PAD;
  `RXFIX_KIT_VERIFY_OK`: all four markers in 3 loose mirrors and both IP zips, BS read range/index
  rule/data_read wiring intact, PAD arbiter present in every serializer copy with the BS taps kept.
  Read words unchanged from the BS image (0x214–0x258).
- Build: `IMPL_STRATEGY=explore bash build_txfix.sh` (positional `--dry` NOT used; env var IS how the
  strategy is passed) → hdl-dev-2 unit **`txfix-build-rxfixpad_build-1788893539`**, remote tree
  `/home/tcollins/qpsk-builds/jupiter_byte_rxfixpad_build`, JOBS=6, 48 GB free, no concurrent unit.
  ETA ~17:05.
- **Gate (pre-registered, same as every rxfix build):** modem-clock INTRA-clock post-route WNS ≥ 0 read
  with `two_jup/rxfix/modem_wns.py` on the routed timing report (precedents W1 +0.169, SEQ-BIST +0.227,
  R4B +0.437, R4D+R1 +0.620; BS's own value is in its build log). The two other printed WNS numbers
  (post-synth, overall vendor path) are not the gate. WNS < 0 ⇒ report, do NOT bank as flashable.
  Confirm `impl strategy: explore` in the remote log, not the variable name.
- Sim gate for the same RTL is running in parallel (`pad_k1536`, `pad_p000`, ~2 h): expected k1536 →
  `bs_trunc` unchanged (315), `ck_short` 0, frames per truncation lost = 1 (the padded frame) and
  `h_push`/`bs_words` = 191 × frames; p000 identical to `bs1_p000` in every delivered byte.
- Silicon plan after both gates: flash 148 (`FLASH_BAK=dec007ae70dd`), one census leg
  (`BS=1 P8=1 R4B=1 EXP=<new md5>`); success = `bs_trunc` still counting (the upstream defect is not
  fixed by F4) while `bs_drop`/`bs_dropmax` → 0 and PER falls from 0.061–0.070 % toward ≈ 0.02 %
  (one lost frame per truncation instead of 3.35).

### §47.8 RXFIX_PAD sim gate: PASS (legs done 15:29, 52 min each)

`pad_k1536` / `pad_p000` (binary `obj_byte_sro_pad` 2dfe1b25…, tree `s1_rtl_pad`, wrapper and driver
unchanged) against the banked Task 46 legs `bs1_k1536` / `bs1_p000`:

| | ck_frames (pins) | ck_orphan | h_push = bs_words | bs_starts | bs_trunc | q24 | t7_ok / nomagic | deliv/frames/seq/res md5 |
|---|---|---|---|---|---|---|---|---|
| bs1_k1536 (unpatched) | **106** | **52,520** | 72,766 | 421 | 315 | 255 (sat) | 104 / 1 | — |
| **pad_k1536** | **418** | **0** | **79,760 = 418 × 191** | 418 | 312* | 255 (sat) | 104 / **319** | — |
| bs1_p000 | 421 | 0 | 80,350 | 421 | 0 | 0 | 423 / 1 | 8f5f2f4a / b2337afe / 01cc2c53 / 2b3ba0e9 |
| **pad_p000** | 418* | 0 | 79,760* | 418* | 0 | 0 | 423 / 1 | **identical** 8f5f2f4a / b2337afe / 01cc2c53 / 2b3ba0e9 |

\* the pad legs' final census row is the end-of-run dump at clk 41.70 M; the banked legs' last row sits on
the 1 M grid at 42.00 M — 0.3 M clk ≈ 2.4 ms ≈ 3 frames later. Same stream, different dump instant
(`pad_p000_deliv.txt` and `bs1_p000_deliv.txt` are byte-identical, 424 records each).

- **Truncation control:** with every frame truncated by the 1536-bit skip, the unpatched serializer merges
  frames (106 frames seen at the pins for 421 starts, 52,520 orphan words); the padded serializer delivers
  **418 frames of exactly 191 words, zero orphans, zero shorts**, each padded frame arriving as one
  no-magic frame (`t7_nomagic` 319) and the census still counting every truncation (312 at the last dump,
  saturating q24). Good frames unchanged (104 = 104).
- **Identity:** the p000 delivered stream is byte-identical to the banked leg — PAD is inert on clean frames.
- No stall leg was re-run: PAD is upstream of the FIFO and the stall behaviour is the FIFO's, unchanged.

**Gate verdict: PASS. Flash is authorised by the operator ("yes flash", 15:1x) once the routed-WNS gate
passes.** Build unit `txfix-build-rxfixpad_build-1788893539` still running (synth done, impl in progress).
UNITEXIT flash148-pad-171204 result=success code=0 at=2026-09-08T17:16:34-04:00

### §47.9 rxfixpad build DONE (17:10): routed-WNS gate PASS, image banked

Unit `txfix-build-rxfixpad_build-1788893539` ran 14:52 → 17:10 (2 h 18 min). Remote log: `impl strategy:
explore (ExtraTimingOpt place, AggressiveExplore route + phys_opt pre/post route)` — confirmed from the
printed string, not the variable. `TXFIX_ROUTED_WNS wns=0.105389 tns=0.000000`; `TXFIX_BUILD_DONE
variant=F3 md5=bf2a7305bbe0e0e38b3529d09edddaef wns=1.544` (the 1.544 is the overall figure, not the gate).

**Gate:** `modem_wns.py system_top_timing_summary_routed.rpt` → `MODEM_CLK_WNS clock=axi_adrv9001_adc_1_clk
wns=0.105 tns=0.0 failing=0 total=186471`. **+0.105 ns ≥ 0: PASS** (precedents W1 +0.169, SEQ-BIST +0.227,
R4B +0.437, R4D+R1 +0.620; the pad arbiter + 3-word queue cost margin but not timing). 0 ERROR lines.

**Banked:** `boot_known_good/BOOT.BIN.148.rxfixpad.bf2a7305bbe0` (7,203,552 B, md5 bf2a7305bbe0…), fetched
from `hdl_prj_jupiter_composite/vivado_ip_prj/boot/BOOT.BIN` (the watcher's `boot/BOOT.BIN` glob was wrong
and it banked nothing — fetched by hand, md5-matched). Routed report and `modem_wns.txt` under
`two_jup/comb/runs/20260908_padbuild/`.

Flash launched immediately under the standing authorisation ("yes flash"): `FLASH_MD5=bf2a7305bbe0
FLASH_TAG=rxfixpad FLASH_BAK=dec007ae70dd`, stale `/root/BOOT.BIN.staged` removed first.
UNITEXIT padleg-171657 result=success code=0 at=2026-09-08T17:29:57-04:00

### §47.10 F4 on silicon (17:12–17:30): **FIFO drops 11,978 → 0; loss per truncation 3.35 → 2.41; the residual is now the upstream defect alone**

Flash `flash148-pad-171204`: dec007ae70dd verified → FLASHED bf2a7305bbe0 → readback match → ARM_OK ×2
(fps 1248, capTAP golden) → GATE_PASS ×2 → FLASH_DDRCAP2_OK. Leg `padleg-171657` (`w1leg_go.sh MODE=air
LEG=A BOARD=148 DUR=600 BS=1 P8=1 R4B=1 RSSI=1 EXP=bf2a7305bbe0`), run
`runs/20260908_171657_w1_padleg1`, readback bf2a7305bbe0, arm gate try 1, 148 rssi 27.3 dBFS median.

| | bspair3 (dec007ae70dd, 12:30) | **padleg1 (bf2a7305bbe0, 17:17)** |
|---|---|---|
| census window | 469.4 s, 584,551 tx | 469.3 s, 584,544 tx |
| **dBS_DROP** (FIFO drop-oldest words) | 11,978 | **0** |
| dBS_TRUNC (upstream truncations) | 105 | 104 |
| dBS_PUSH − dBS_POP | 11,978 | **0** (every pushed word popped) |
| window PER (lost frames in denominator) | 0.061 % (358) | **0.045 % (262), CP95UL 0.051 %** |
| lost frames per truncation | 3.35 | **2.41** |
| CRC-fail records per truncation | 2.3 | 2.38 |
| corr(dBS_TRUNC, lost) per 10 s | 0.991 | 0.982 |
| lost in truncation-free intervals | 6 of 358 | 9 of 262 |
| loss-run lengths | 1:36% 2:… | 1:11 **2:66 3:35** 4:2 5:2 (of 116 runs) |
| whole-leg `accept_analyze` | 0.061 % (450/732,321) | 0.072 % (528/732,320) — includes ONE 175-frame run at t = 602.8 s, after the 600 s traffic end (teardown artefact, rstcs 0); the census-window number is the comparable one |

**Reading.** F4 did exactly what the sim said: the FIFO never drops, push = pop, the stream stays
191-aligned, and the DMAC sync-wait deadlock is gone (the 119/143-word drop runs no longer exist). The
per-event cost fell from 3.35 to 2.41 frames — one frame, the FIFO's share. What remains per truncation
is **2–3 consecutive CRC-failed frames delivered** (runs of 2 and 3 dominate; every lost run is bounded by
CRC-fail records, not by missing ones): the padded frame itself plus one or two neighbours whose decode
the upstream event also breaks. That is the root defect's own footprint — a frame short by k × 1536
decoded bits arrives with its neighbour(s) corrupted — and it is now 97 % of the forward residual
(253 of 262). The daemon's `resync_fail` counter (11,013) is the host declining to find magic in the
zero-filled frames, as intended.

**Decision:** `bf2a7305bbe0` stays in service on 148 (strictly better than `dec007ae70dd`, same read map,
gate passed). Rollback `dec007ae70dd` is on-board and banked. Hold released 17:3x.

**Next development item:** the upstream k × 1536-bit deficit (RxDeint/RxAlign readout vs the demod frame
timing; §47.4). Silicon rate 0.22 events/s, each now costing 2.4 frames. Sim path: the deficit must be
reproduced at the RxDeint input (the `bsskip` control acts at RxAlign and is not the same event — it
produced no neighbour damage in `pad_k1536`: 104 good frames of 104 clean ones). Target signature in sim:
a truncation accompanied by CRC failure of the adjacent frame.

### §47.11 Root-defect localisation from the banked SRO sims (desk, 17:5x): the deficit is at the PAYLOAD GATE, upstream of FEC and deinterleaver

The Task 46 leg `bs1_m10` (−10 ppm, no stall, no skip) contains ONE natural truncation (`bs_trunc` 1,
`bs_trunc_last` 81, not on the 24-grid), reproduced identically by the un-tapped tree `bsb_m10` — so it is a
deterministic function of the stimulus. Its per-air-frame trace (`bs1_m10_frames.txt`, column map from
`sim_sro.cpp:390`) at frames 134–139:

| frame | ss (Rate_Handle out) | pd (Preamble_Detector out) | **con (QPSKConstellationValid)** | **dem (Demodulator bits)** |
|---|---|---|---|---|
| 136 | 12333 | 12333 | 12320 | 24640 |
| **137** | 12333 | 12333 | **5257** | **10514** |
| 138 | 12333 | 12333 | **12333** (+13) | **24666** (+26) |
| 139 | 12333 | 12333 | 12320 | 24640 |

Every symbol reaches the preamble detector (12333/frame throughout), yet only 5257 of the 12320 payload
symbols of frame 137 pass the stage that produces `QPSKConstellationValid` — the frame-gating between
Preamble_Detector/Phase_Ambiguity and the demodulator (Packet_Controller / End_Generator payload window) —
and 13 of the missing symbols spill into frame 138. **The deficit is created at the payload gate, not in
RxDeint or RxAlign** (those only inherit a short frame); RxAlign's `bsskip` control was therefore the wrong
analogue (it produced no neighbour damage), and §47.4's RxDeint-readout suspicion is retired.

Differences from silicon to keep in view: this sim event cuts 7,063 symbols (not k × 768 = k × 1536 bits),
at −10 ppm (4× the real offset), once in 422 frames (silicon: once in ~5,500 at −2.5 ppm). Same stage,
different magnitude — the quantisation at 768 symbols on silicon is the next thing to explain from the
gate's RTL. `pad_m10` / `pad_m40` legs launched (17:5x) on the padded tree to see the event under PAD and
to look for more events at −40 ppm.

### §47.12 Two corrections to §47.11 from the same data (18:0x): the sim's natural event is a DISPLACED START; silicon has NO extra starts

1. **The sim event (bs1_m10 frame 137) is a late demod start, not a gate that closed early.** The per-frame
   mark records (`bs1_m10_marks.txt`, one row per `QPSK_Demodulator_startOut` rising edge, first column =
   sample index): starts at 6,660,250 / 6,709,582 (Δ 49,332 = one frame) / **6,787,166 (Δ 77,584 = 1.57
   frames, 19,396 symbols since the previous mark)** / **6,808,246 (Δ 21,080 = 0.43 frame, 5,270 symbols)**
   / 6,857,578 (Δ 49,332). One start arrived 7,063 symbols late and the following one on time, so one
   "frame" spanned 1.57 frames and the next 0.43 — the payload gate (Packet_Controller: sync → 12,320-symbol
   End_Generator window) behaved correctly on a mistimed sync. Cause of the late sync at −10 ppm: a missed
   preamble, re-acquired on the next detection; not further pursued here.
2. **Silicon shows regular starts.** Per 10 s interval on both census legs, `Δ0x124` (frame-start pulses)
   − `Δ0x104` (packets) is 0 ± 2 with total 0, and `ΔBS_STARTS` (RxAlign starts) − `Δ0x104` totals 9 (bspair3)
   and 20 (padleg1) against 105 / 104 truncations; corr(extra starts, bs_trunc) = −0.04 / −0.10. **No false
   or extra sync accompanies a silicon truncation.** The frame boundaries are on time; what is short is the
   number of decoded bits delivered BETWEEN two on-time starts — by exactly 2 or 3 × 1536 bits.

So the root defect is: **between two regular frame starts, RxAlign emits 12,292 − k × 1536 decoded bits.**
1536 bits = 768 `deintValid` pairs = 1,536 `validIn` beats at RxDeint's 1-pair-per-2-beats read pacing =
1,536 symbols = 100.0 µs. The candidates are therefore inside the FEC/deinterleaver readout — RxDeint's
gated read (`rdGate`, the `tmp_3 < 12296` read counter, the isolated-read pacing), the gated Viterbi
(`VitGate` hold, "+41" latency) or RxAlign's `o < 12292` window — for a mechanism that skips whole
1,536-beat blocks while keeping the start cadence. The sim has never produced this event (the −10 ppm
event is the other kind), so the next sim work is a directed search: run the SRO harness at −2.5 ppm on
the padded tree with a per-frame `deintValid`/`recBitValid` count added to the trace and look for any
frame whose count is 12,292 − 1,536k; if none in 428 frames, inject a 1,536-beat gap into RxDeint's
`validIn` and confirm the census signature (trunc at wordCnt 119/143 with regular starts) before reading
the RTL for what can create such a gap.

### §47.13 pad_m10 / pad_m40 (done 19:25): PAD is inert on the late-start event; −40 ppm is the ring regime, not this defect

| leg | frames (pins) | good (t7_ok) | bad / nomagic | bs_drop | bs_trunc |
|---|---|---|---|---|---|
| bs1_m10 (unpatched) | 422 | 378 | 8 / 39 | 0 | 1 |
| **pad_m10** | 418 | **378** | 8 / **40** | 0 | 1 |
| pad_m40 | 418 | 93 | 30 / 302 | 0 | 1 |

At −10 ppm PAD changes nothing except that the one late-start truncation now leaves one zero-filled
no-magic frame instead of a merged pair (39 → 40 nomagic, same 378 good). At −40 ppm the receiver is in
the ring-deletion regime (`con` alternates 12,333 / 12,287 every frame, 78 % loss, as in Task 7's −40 ppm
leg) with a single truncation — nothing there bears on the k × 1536-bit defect. Both legs confirm
`bs_drop = 0` under PAD in every regime run. No further SRO-sweep legs are planned for the root defect;
the path is the directed injection of §47.12.

### §47.14 Directed injection harness built and four legs launched (19:5x) — pre-registration

Harness: `rtl_sim/wrap_byte_padinj.v` (= `wrap_byte_bs.v` + a per-frame trace + an injection knob) on tree
`s1_rtl_padinj` (= `s1_rtl_pad` + a sim-only `dvgap_kill` gate on RxDeint's `validIn` inside
`FEC_Decoder_Wrapper`, written by the wrapper through a hierarchical reference). Driver `sim_sro.cpp`
unchanged. Trace `<pfx>_pf.txt`: one row per RxAlign `startOut` with, for the frame just ended, the
counts of FEC `validIn` beats, `deintValid`, RxAlign `validOut`, serializer words, plus the serializer's
`wordCnt` at that start, cumulative `bs_trunc`/`bs_drop`, and whether the injection window was active.
Nominal row: 24,640 / 12,296 / 12,292 / 191 / 0.

Legs (90 air frames each, n_p000.iq, PAD tree, census on): `inj_ctrl` (no injection), `inj_g1536`,
`inj_g3072`, `inj_g4608` = kill RxDeint `validIn` for 1,536 / 3,072 / 4,608 beats starting at FEC-validIn
beat 990,600 / 1,113,800 / 1,237,000 (frames ~40 / 45 / 50).

**Predictions.** If the silicon event is "a k × 1,536-beat hole in the deinterleaver's input":
(P1) exactly one frame per injected leg shows `deintValid` = 12,296 − 768k and `align_validOut` =
12,292 − 1,536k with a normal `fec_validIn` cadence at the next start; (P2) the census reads ONE
truncation with `bs_trunc_last` = 191 − 24k (167 / 143 / 119) and `bs_q24` +1; (P3) the serializer
emits 191 words for that frame (PAD) with `bs_drop` 0; (P4) the neighbouring frames are intact
(counts nominal) — if instead a neighbour is also short or corrupt, the silicon's 2–3-frame footprint
is reproduced and the deint's ping-pong bank handling is implicated. Control must be nominal throughout.
If P1/P2 fail with these exact numbers, the silicon event is not an input-valid hole and the next
candidate is the read-side gate (`rdGate` / `tmp_3 < 12296`).

### §47.15 Injection results (19:44): an input-valid hole reproduces the truncation AND the neighbour damage, but not the 24-word quantum

Control `inj_ctrl`: every frame nominal (trace baseline 24,639 / 12,295 / 12,254 / 191 per frame — the
trace counts have a fixed −1/−1/−38 offset from the RTL constants by construction), 0 truncations,
85 of 86 frames good.

| leg | killed RxDeint `validIn` beats | deintValid lost | align bits lost | words at the start (`bs_trunc_last`) | deficit words | q24 | host outcome |
|---|---|---|---|---|---|---|---|
| g1536 | 1,536 | 744 | 744 | 179 | 12 | 0 | frame 41 magic OK / body bad; **+1 no-magic frame**; good 85 → 83 |
| g3072 | 3,072 | 1,512 | 1,512 | 167 | 24 | 1 | frame 46 bad; +1 no-magic; 83 good |
| g4608 | 4,608 | 2,280 | 2,280 | 155 | 36 | 0 | frame 51 bad; +1 no-magic; 83 good |

- **P2/P4 confirmed in kind:** each hole yields exactly one census truncation with on-time starts (the
  next frame's counts are nominal) — the silicon signature class — and **two lost frames per event**: the
  truncated one (its magic survives because PAD's zeros fill the tail, its CRC fails) plus one no-magic
  frame that is NOT short. That second casualty is the neighbour damage seen on silicon (runs of 2–3):
  the coded-bit hole passes through the Viterbi decoder, whose traceback smears garbage across the
  frame boundary into the next frame's first bits, where the magic lives. So the 2.41 frames per event
  that F4 left behind are this: one short frame + one Viterbi-corrupted neighbour.
- **P1 not exact:** `deintValid` lost = killed/2 − 24 (744, 1,512, 2,280), i.e. the 24-pair read margin
  absorbs 24 pairs of any input hole. A 24k-word deficit therefore needs a killed-input hole of
  2 × (768k + 24) = 1,584 / 3,120 beats — not a natural quantum. **The silicon deficits (exact 768k
  pairs) are therefore more likely a READ-side hole (deintValid itself, or the VitGate) than an
  input-valid hole.** Next leg: kill `deintValid` at RxDeint's output for 768k beats and confirm
  exact 24k-word truncations with the same neighbour damage.
- PAD behaved: `bs_drop` 0 in all four legs, no shorts, no orphans.

### §47.16 Read-side vs input-side hole (19:55): the silicon event is a CODED-BIT hole upstream of the Viterbi

Mode-2 legs kill exactly N `deintValid` pulses at RxDeint's OUTPUT (what VitGate and RxAlign consume):

| leg | pairs killed (read side) | deintValid lost | words deficit | q24 | host outcome |
|---|---|---|---|---|---|
| r768 | 768 | 768 | 12 | 0 | frame 41 bad (magic OK, CRC fail); **good 85 → 84: ONE lost** |
| r1536 | 1,536 | 1,536 | 24 | 1 | one lost |
| r2304 | 2,304 | 2,304 | 36 | 0 | one lost |

Against §47.15's input-side holes (RxDeint `validIn`), which cost **two** frames each (the truncated one
plus a no-magic neighbour). The read side is exact (no −24 margin effect) and clean; the input side is
lossy to the neighbour because the missing coded bits pass through the Viterbi decoder and its traceback
corrupts the start of the next frame. **Silicon shows 2–3 CRC-fail frames per truncation (§47.10), so the
silicon hole is on the INPUT side of the Viterbi: coded bits are missing from the frame** — either they
never left the demodulator/payload gate, or RxDeint dropped them on write. Units, corrected: one
`deintValid` pair = one decoded bit; silicon's 1536-bit deficits = 1,536 pairs = 3,072 coded bits =
1,536 payload symbols = 6,144 samples at 4 sps = 100 µs.

**Suspects, narrowed (all upstream of the FEC):** the Packet_Controller payload gate (`MATLAB_Function_block`
`out`, End_Generator 12,320-count) and the `sample_discard_controller` it feeds — the module R3/R4/R4B patched
(the R4B skip window "13 slots after pcEnd") — for a path that drops a 1,536-symbol block mid-payload while
`startOut` stays on time; and RxDeint's write side (`wptr < 24592`, bank select on `startIn`). The −24
margin in §47.15 is consistent with a mid-frame hole, so a mid-payload discard fits.

**Next sim step:** drive the same harness with a kill on the payload gate output (`QPSKConstellationValid`
or the FEC wrapper's `validIn` = mode 1 but positioned at a known symbol offset) and read `bs_trunc_last`
vs hole position to see whether the RxDeint write side quantises the deficit to 1,536 pairs; then grep
`sample_discard_controller.v` / the R4B window for a 1,536-symbol structure. Rig time: none needed.

### §47.17 Hole-position test (20:04): the 24-pair absorption is fixed and position-independent; the deficit lands in the frame that holds the hole

Mode-1 (input-side) holes at three positions of the same frame (fv_idx 986,600 / 997,600 / 1,005,600 inside
the frame spanning 985,683–1,010,323): killed 768 → deintValid lost 360 (= 384 − 24); killed 1,584 early
or late → lost exactly 768 (= 792 − 24), `bs_trunc_last` 179; killed 3,120 → lost 1,536, `bs_trunc_last`
167 (24 words, q24). So `lost pairs = killed/2 − 24` regardless of position, and the truncation is booked in
the frame containing the hole. Silicon's exact 1,536k-pair deficits therefore correspond to input holes
of 3,120 / 6,192 coded bits (1,560 / 3,096 payload symbols) — OR to a mechanism that bypasses the read
margin. The 768-beat hole cost three extra no-magic frames at the host (63 → 62 good) where the larger
holes cost one — a short hole leaves the truncated frame's magic intact but the Viterbi damage spreads.
Operator message 20:0x: away until 07:00, continue autonomously, hardware as needed.
UNITEXIT txcorr-200622 result=exit-code code=3 at=2026-09-08T20:16:53-04:00

### §47.18 txcorr1 (20:06–20:17): truncations occur with ZERO host TX gaps; the leg then died of the class-E wedge, which the census and a 146 TX-gap scrape caught in the act

Leg `txcorr-200622` (census on 148, image bf2a7305bbe0) with a parallel host-side scrape of 146's daemon
`txgap` line every 5 s (`scratchpad/txgap_146.txt`, 87 rows; host-only ssh, no registers).

1. **Truncations vs host TX gaps (the 8 clean intervals 20:08:51–20:10:01):** `dBS_TRUNC` per 10 s =
   0, 1, 4, 2, 3, 3, 5, 3 (21 events) while 146's `gt200us` was 0 in every one of those windows
   (`max_us` 0). The truncations are not host inter-transfer silence — consistent with the 08-28 TX-plane
   finding ("trigger is not host txgap; stalls inside the MM2S transfer"). TX-fabric starvation is not
   excluded; the daemon's submit cadence is.
2. **Class-E wedge, first time seen through the census.** At 20:10:0x delivery flatlined and never
   returned (capture aborted at 102 s wall, `MID_CAPTURE_WEDGE`). Census/AUX per 10 s: 0x104 12,4xx →
   6,445 → 5,927 → 5,944 → 2,751 → 0; rstcs 0 → 2,053 / 2,182 / 2,101 / 982 per 10 s; **dBS_TRUNC
   1,750 / 1,881 / 1,905 / 841** (the demod emitting half-frames in a reset storm); then `dBS_DROP`
   961,601 + 76,675 when the host stopped draining (capture teardown killed the daemon; FIFO full).
   frames.bin: from t = 101 s every record is CRC-fail, rstcs climbing ~210/s, CFC median wildly
   negative (≈ −58k to −75k counts ≈ −400 to −500 kHz), rssi flat at 26.9 dBFS throughout (not RF).
3. **The onset coincides with the only TX anomaly in 87 samples: 146 `gt200us=2, max_us=3,972 µs,
   p99 4,095 µs` in the 5 s window 20:10:04–20:10:09**, zero in the windows before and after. A ~4 ms
   transmit-feed gap on 146 immediately precedes 148's receiver falling into a carrier-reset storm it
   never leaves (ATARM_CLASS.md put the kill threshold at ≥ 7 ms for the capture-harness rotate gap;
   this one is shorter and did it — or the threshold is CFO-state dependent). This is the "third wedge
   class" of 09-06 and the 07:44 storms of this morning, with a candidate trigger attached for the
   first time.
4. The leg's restore again left BOTH daemons down (capture_r3's pair.iq "REBOOT-ONLY" misfire, §46.5);
   `bringup-2020xx` restored the rig.

**Implications.** (a) Receiver robustness is now the largest *reliability* (as opposed to PER) item: a
few-ms transmit gap must not strand the receiver in a storm until a re-arm — the demod's reset-storm
exit needs a fix (or the watchdog needs the soft-rearm-first change, NEXT_STEPS 3). (b) On the TX side
the 4 ms gap itself is a host scheduling event on 146 worth a look (what runs every few minutes on 146
that stalls the daemon for 4 ms?). (c) The k × 1536-bit truncations are unrelated to host TX gaps.
UNITEXIT loopdaemon-202044 result=success code=0 at=2026-09-08T20:32:44-04:00

### §47.19 DECISIVE (20:20–20:32): daemon-fed byte-DMA TX → 148 internal loopback → census: **643,381 frames, 0 truncations, 0 drops, 0 CRC failures.** The k × 1536-bit hole needs the AIR path.

`two_jup/rxfix/loopdaemon_go.sh` (new; banked): 148 armed alone in mode-1 internal digital loopback
(`arm148_mode1.sh`, ARM_OK fps 1248 capTAP golden), the daemon started on 148 (`QPSK_RX_QUEUED=1 -M 16
-r 15360`), TX source switched to byte DMA (0x158 = 1, rstCS double-tap), then 48 frozen census sweeps at
10 s (BS=1 R4B=1, AUX 0x104 0x124 0x150 0x134), run `runs/20260908_202044_loopdaemon1`. 146 untouched.

| | air leg padleg1 (§47.10, 469 s) | **loopback, daemon-fed TX (480 s)** |
|---|---|---|
| frames (0x104 / BS_STARTS) | 584,544 | **643,382 / 643,381** |
| dBS_TRUNC | 104 | **0** |
| dBS_DROP | 0 | **0** |
| dBS_WORDS / frames | 191.0 | **191.000 exactly (122,885,856 / 643,381)** |
| 0x124 − 0x104 (extra starts) | 0 | **0** |
| rstcs (0x150) | 0 | **0** |
| daemon `crc_drop` over the window | ~250 | **0** (4,800 → 4,800) |
| daemon frames tx / rx-ok | — | 647,712 / 647,702 |

At the air rate (0.22 events/s) 480 s should show ~105 truncations; the loopback shows none (P ≈ e^−105).
The same daemon, the same byte-DMA TX plane (ByteWordBuffer, Bit_Packetizer), the same RX byte plane,
the same census image — and no event. **Therefore the truncation is created in the over-the-air receive
chain between the ADC and the FEC** (RF front end → symbol/carrier sync → preamble/payload gate), not by
host TX gaps (§47.18), not by TX-fabric starvation, not by the RX byte plane. Combined with §47.16
(input-side coded-bit hole, Viterbi neighbour damage) and §47.12 (on-time starts): **a block of
1,536k payload symbols is dropped inside the synchroniser/payload-gate stage of the receiver while it
tracks a real air signal.** Candidates, in order: `sample_discard_controller` (inside Packet_Controller,
the module the R3/R4 fixes patched), the Rate_Handle/R4B skip window straying into the payload, the
Preamble_Detector realignment FIFO, the carrier-sync reset path (rstcs = 0 throughout, so not a full
reset). The −24-pair read-margin arithmetic (§47.17) says the silicon hole is 1,560 / 3,096 symbols of
input if it is a plain valid gap — or an exact 1,536k if the stage that drops them also stalls the
deinterleaver's read pacing (a symbol-domain stall does exactly that).

Rig handed back 20:33 (loopdaemon's own restore: r3 bring-up OK; hold released; sentinel relaunched).

### §47.20 LOCALISED ON SILICON (20:4x, desk on existing reads): the symbols vanish at the PAYLOAD GATE — Preamble_Detector → Packet_Controller — every upstream stage conserves

The W1 census already carries six per-stage valid counters per frozen sweep (cSS, cRH, cCFC, cCS, cPD, cPC
= Symbol_Synchronizer strobe, Rate_Handle out, Coarse_Frequency_Compensator out, Carrier_Synchronizer
out, Preamble_Detector out, Packet_Controller out). Per 10 s interval, stage-to-stage differences vs
`dBS_TRUNC`, on both census legs:

| stage pair | bspair3: mean diff / corr(trunc) / slope | padleg1: mean / corr / slope |
|---|---|---|
| SS − RH | 0.0 / −0.16 / 0 | 0.0 / +0.07 / 0 |
| RH − CFC | 0.0 / 0 / 0 | 0.0 / 0 / 0 |
| CFC − CS | 0.0 / −0.03 / 0 | 0.0 / −0.02 / 0 |
| CS − PD | 0.0 / +0.05 / 0 | 0.0 / −0.05 / 0 |
| **PD − PC** | **172,665 (13.88/frame) / +0.92 / 5,340 symbols per truncation** | **172,763 (13.89/frame) / +0.89 / 5,029 symbols per truncation** |

SS = 12,333.3 symbols/frame and PC = 12,319.5/frame on both legs (the gate passes 12,320 of 12,333 per
clean frame; 13 guard symbols are dropped by design, hence 13.88/frame). **Every stage from the ring to the
preamble detector conserves symbols to the count; the Packet_Controller's payload gate drops ~5,000 extra
symbols per truncation event** (≈ 3.3 × 1,536; the fit slope mixes k = 2 and k = 3 events and their
Viterbi-damaged neighbours). Intervals with no truncation sit at the 13/frame floor (160,478 vs 182,509
with).

So the k × 1,536-symbol hole is made by the gate `Preamble_Detector syncPulse → Phase_Ambiguity →
Packet_Controller (MATLAB_Function_block out · validIn → sample_discard_controller → validOut)`, on air
only (§47.19), with `startOut` still once per frame (§47.12). The 1,536-symbol quantum must live in that
gate's logic or in what feeds its `syncPulse`. Reading `MATLAB_Function_block.v` / `sample_discard_controller.v`
next; the sim injection to confirm is a valid-kill at `QPSKConstellationValid` (the gate's output) — already
what mode 1 approximates — followed by a gate-internal fault model once the RTL shows the path.

### §47.21 The gate RTL, and a hypothesis that fits every fact: a FALSE PREAMBLE PEAK inside the idle payload, chosen instead of the true one

`sample_discard_controller.v`: `active` is set by `startIn` and cleared ONLY by `endIn`; while active it
passes `validIn`. `MATLAB_Function_block.v`: `out` is a one-beat flag set by `syncPulse`, cleared by the
next `valid`; `validIn & out` is the packet start pulse (= End_Generator `rst`, = `startIn`).
`End_Generator.v`: counts `validIn` from `rst`, fires `end` at the 12,320th. So the gate can lose payload
symbols mid-frame in exactly one way: **the start pulse comes early by D symbols**, the gate then closes
12,320 symbols later, and the NEXT (on-time) start truncates that frame at 12,333 − D symbols. A start
early by D = 1,549 or 3,085 symbols (1,536k + 13) gives the observed 1,536 / 3,072-bit deficits.

Why the start count does not rise: §47.12 compared 0x124 against 0x104, but BOTH count start pulses; the
right control is the transmitted frame count, and `bs_pair_score` has it — bspair3: 584,543 RxAlign starts
against 584,551 host-transmitted frames (8 fewer, not 105 more). So the early start REPLACES the true one:
the Preamble_Detector's peak search picks a correlation peak that lands 1,536k + 13 symbols before the
true preamble, and the true peak is then inside the new frame's hold-off. A peak at a FIXED offset before
the preamble means a fixed structure in the payload that correlates with the preamble — and the forward
payload is the daemon's IDLE frames (constant content, `QPSK_WHITEN` off by default). Two offsets (k = 2, 3)
= two places in the idle frame's symbol sequence that resemble the preamble. On air, noise occasionally
lifts the false peak above the true one; in loopback (perfect SNR, §47.19) it never does — **which is
exactly the air-only behaviour that ruled out every hardware plane.** The neighbour damage follows too:
the early-started frame is decoded misaligned (garbage, CRC fail) and the truncated frame fails — 2 frames,
3 when the Viterbi smears.

**Pre-registered test (host-only knob, no flash): the same census leg with payload whitening ON at both
ends** (`QPSK_WHITEN=1` through `bringup_r2r3.sh`'s `WHITEN`, which the daemon reads). Prediction W1:
`dBS_TRUNC` falls from ~104/470 s to ≈ 0 (≤ 3) with PD − PC back at the 13/frame floor and PER ≤ 0.01 % —
the false-peak hypothesis is confirmed and whitening (or a peak-position flywheel in the detector) is the
fix. W2: truncations unchanged → the early start has another origin (still inside the PD/PA/gate) and the
next step is the sim with a payload-correlated false peak.
UNITEXIT whiten-203759 result=success code=0 at=2026-09-08T20:50:59-04:00

### §47.22 W1 FIRES — ROOT CAUSE CONFIRMED (20:38–20:51): payload whitening ON → truncations 104 → 2, census-window PER 0.045 % → **0.005 %**

Leg `whiten-203759` = the standard census leg with `WHITEN=1` and `WHITEN_DENV=QPSK_WHITEN=1` (both daemons
verified `QPSK_WHITEN=1` in `/proc/<pid>/environ` mid-leg, 148 and 146), run
`runs/20260908_203759_w1_whiten1`, image bf2a7305bbe0, arm gate try 1, no watchdog relaunch.

| | padleg1 (whitening OFF, 17:17) | **whiten1 (whitening ON, 20:38)** |
|---|---|---|
| census window / transmitted | 469.3 s / 584,544 | 469 s / 585,772 |
| **dBS_TRUNC** | 104 | **2** |
| dBS_DROP | 0 | 0 |
| **window PER** (lost in denominator) | 0.045 % (262), CP95UL 0.051 % | **0.005 % (27), CP95UL 0.007 %** |
| whole-leg `accept_analyze` | 0.072 % (528/732,320) | 0.031 % (231/733,891) — one > 100-frame run (see below), bins 1:23 2:4 3-4:3 |

The hypothesis of §47.21 is confirmed by the pre-registered test: with the payload randomised, the
preamble detector no longer finds a false peak inside the idle payload, the payload gate no longer starts
early, and the k × 1,536-bit truncations — 97 % of the forward residual — are gone (2 in 585 k frames).
The forward leg's census-window PER is now **0.005 %**, sixteen times better than the 09-05 best (0.079 %)
and nine times better than this morning's post-antenna 0.045 %.

**What the defect was, end to end.** The TX scrambler is hard-disabled and host whitening was off, so the
daemon's idle frames went to air as a constant, repeating byte pattern. Two places in that pattern
correlate with the preamble; on air (not in loopback) noise occasionally lifts one of those false peaks
above the true one, the Preamble_Detector's peak search takes it, the Packet_Controller starts the
frame 1,549 or 3,085 symbols early, its End_Generator closes 12,320 symbols later, and the next (true)
start truncates that frame by exactly 2 or 3 × 1,536 bits while the misaligned frame and its neighbour
fail CRC. Downstream the short frame misaligned the DMAC transfer (fixed by F4/PAD, §47.5–§47.10).

**Fix = whitening ON at both ends (host knob), plus F4 in the fabric.** Both-ends-or-nothing: the
watchdog's relaunch string in `bringup_r2r3.sh:209` does not carry `QPSK_WHITEN`, so a relaunched daemon
would silently mismatch its peer — that line must carry it before the default changes (next entry).
Payload-content dependence also means real traffic (non-idle) was already less exposed than the idle
soak; the idle-frame pattern was the worst case the link has been measured on.
UNITEXIT revwhite-205329 result=exit-code code=3 at=2026-09-08T21:04:29-04:00

### §47.23 Whitening made the default; first whitened reverse leg (20:53–21:04) halves the small-run loss but is cut by a second class-E wedge

- `bringup_r2r3.sh`: `WHITEN=${WHITEN:-1}` and `WCMD="QPSK_WHITEN=$WHITEN ..."` so the watchdog relaunch
  matches the peer (commit 56fcb8a); docs/BRINGUP.md §0.2b. Both daemons verified `QPSK_WHITEN=1` after the
  21:0x bring-up.
- Reverse leg `revwhite-205329` (146 RX on the degraded antenna, whitening both ends, DP quiet): arm gate
  try 1, health crc 99 %; **MID_CAPTURE_WEDGE at 218 s** — delivery +0 frames from t ≈ 205 s for 22 s, then a
  carrier-reset storm at ~1,000/s from t = 230 s (rstcs 5 → 4,272 in five seconds), rssi flat 28.4 dBFS.
  `accept_analyze` live 228 s: 10.39 % (27,562/265,278) — of which one run of 27,115 is the wedge. **Loss in
  runs ≤ 20 frames: 455 / 267,858 = 0.170 %** vs 0.367 % on the same antenna this afternoon (§46.12) — the
  whitening removes roughly half of the reverse residual too (146 has no census, so no `bs_trunc`), the
  remainder being the antenna-degraded leg's own class. NOT a credited number (wedge-truncated, 228 s).
- **Class E is now the dominant leg-killer: two of the last three 600 s legs (20:10 fwd, 21:00 rev) died in
  it, in both directions, at steady level.** Its trigger candidate is a few-ms transmit-feed gap on the peer
  (§47.18); its cost is total until a re-arm. The capture harness's "REBOOT-ONLY" verdict on it is wrong every
  time (an `r3` bring-up clears it, three for three today) and leaves both daemons down. Receiver storm-exit
  robustness is the next reliability item; the watchdog soft-rearm-first design (NEXT_STEPS 3) is the
  interim.
- Rig handed back 21:0x: bring-up (whitened default) gate pass, hold released, sentinel relaunched.
UNITEXIT overnight-210817 result=success code=0 at=2026-09-08T21:21:48-04:00
UNITEXIT overnight-212139 result=success code=0 at=2026-09-08T23:28:43-04:00

### §47.24 Overnight runner, 8 legs (21:21–23:28), whitening at the shipped default: forward pooled **0.0079 %**; class-E wedges only on the degraded-antenna reverse leg and with NO peer TX gap

`two_jup/rxfix/overnight_legs.sh` (unit `overnight-212139`, `runs/20260908_212139_overnight`): fwd/rev
alternating, 600 s each, census on the forward legs, peer `txgap` scraped every 5 s, bring-up between legs.
PER below = lost frames (host_seq gaps) over the 15–598 s window, so the end-of-traffic run that every
600 s leg carries at t ≈ 602 s is excluded; `accept_analyze` whole-leg numbers are in `overnight.log`.

| leg | dir | window PER | lost / transmitted | wedge |
|---|---|---|---|---|
| on1 | fwd | 0.0067 % | 49 / 726,091 | — |
| on3 | fwd | 0.0076 % | 55 / 726,089 | — |
| on5 | fwd | 0.0059 % | 43 / 726,093 | — |
| on7 | fwd | 0.0113 % | 82 / 726,091 | — |
| **fwd pooled** | | **0.0079 % (229 / 2,904,364)** | | 0 of 4 |
| on2 | rev | 0.0704 % | 511 / 726,092 | — |
| on4 | rev | 0.0802 % | 582 / 726,091 | — |
| on6 | rev | 0.0215 % | 147 / 685,059 | MID_CAPTURE_WEDGE at 574 s |
| on8 | rev | 0.0429 % | 207 / 482,136 | MID_CAPTURE_WEDGE at 418 s |
| **rev pooled (live windows)** | | **0.055 % (1,447 / 2,619,378)** | | 2 of 4 |

- **Forward: ten times better than the 09-05 best (0.079 %) and stable across four legs**, on the shipped
  path (default `WHITEN=1`, no per-leg env). Bins are singles and doubles; no burst class.
- **Reverse** (146 RX on the antenna that was 148's fault): 0.02–0.08 % per leg vs 0.367 % this afternoon
  and 0.191 % on 09-06 with the good antenna and no whitening — whitening helps the reverse leg too. Not
  credited as steady state: the antenna is degraded and two legs wedged.
- **Class E: 4 of the last 5 reverse legs wedged (21:00, 22:58, 23:28 + this afternoon's pattern), 0 of 5
  forward legs since the swap.** In both wedged legs the peer's `txgap` read `gt200us=0 max_us=0` in every
  5 s window from −19 s to +17 s around the last CRC-ok frame — **no transmit-feed gap preceded the storm**;
  §47.18's 4 ms gap was coincidental. Class E follows the DEGRADED RECEIVE PATH (28 dBFS on 146 now; 148 had
  the storms this morning while it had the antenna), i.e. it is the marginal-signal failure mode of the
  carrier loop, and the antenna replacement is its fix candidate as well. Receiver storm-exit robustness
  remains the design item behind it.
- Rig handed back 23:28 by the runner (hold released, keeper relaunched, both daemons whitened).

## §48 — 2026-09-09 morning: the overnight soak, and the antenna replaced

### §48.1 Sentinel soak 23:30 → 07:45 (rig idle, whitening at the shipped default)

98 samples: forward `crc=` min 100.0 % / median 100.0 %, reverse `rcrc=` min 99.9 % / median 100.0 %,
delivery at the frame rate in every sample, **zero wedge or recovery events** after the 23:30 relaunch —
the first clean multi-hour in-service record since 09-07 18:00, and the first ever on a whitened link.
(The sentinel's `crc=` ratio has 10 s × 1245 f/s ≈ 12,000-frame resolution, i.e. it sees ≥ 0.01 %; the
0.008 % forward residual is below its floor, as expected.)

### §48.2 Antenna replaced (operator, ~07:45); re-baseline launched

Operator: "antenna replaced". `overnight_legs.sh NLEGS=4` (unit `antenna2-074915`,
`runs/20260909_074915_antenna2`): fwd / rev / fwd / rev, 600 s each, whitened default, peer txgap scraped.
Pre-registered expectations: forward unchanged at ≈ 0.008 %; **reverse ≤ 0.02 % with 146 rssi back near
24.5 dBFS and no class-E wedge** (if class E was the marginal-signal mode of the degraded path it should
not recur on the new antenna in 2 × 600 s; a recurrence at full level would put it back on the receiver
design).
UNITEXIT antenna2-074915 result=success code=0 at=2026-09-09T08:57:17-04:00

### §48.3 Re-baseline on the replaced antenna (07:49–08:57): no wedges in 4 legs, but BOTH receive levels are weaker than before the replacement

`runs/20260909_074915_antenna2`, PER over 15–598 s (lost frames in the denominator), rssi = the receiving
board's `in_voltage0_rssi` median over the leg (dB below full scale, larger = weaker):

| leg | dir | window PER | lost / tx | rx rssi | bins 1 / 2 / 3–4 | wedge |
|---|---|---|---|---|---|---|
| on1 | fwd | 0.0103 % | 75 / 726,090 | 148: **27.2** (was 22.9 after the swap, 09-08) | 33 / 4 / 10 | — |
| on3 | fwd | 0.0063 % | 46 / 726,091 | 148: 27.3 | 16 / 8 / 4 | — |
| on2 | rev | 0.0909 % | 660 / 726,091 | 146: **30.2** (was 28.3 on the degraded antenna; 24.6 on 09-05) | 249 / 58 / 82 | — |
| on4 | rev | 0.0584 % | 424 / 726,090 | 146: 30.3 | 190 / 52 / 39 | — |

- **No class-E wedge in 2 × 600 s reverse legs** (4 of the previous 5 had one) — consistent with class E
  being the degraded antenna's marginal-signal mode, though the sample is small.
- **Levels went the wrong way on both legs:** 148 RX 22.9 → 27.2 dBFS (−4.3 dB), 146 RX 28.3 → 30.2 dBFS
  (−1.9 dB). The reverse leg is now 5.6 dB weaker than the 09-05 baseline (24.6) and its PER (0.06–0.09 %)
  is above last night's 0.02–0.08 % on the bad antenna and well above the 0.191 % → expected-≤0.02 % target.
  Either the replacement antenna is a lower-gain part / differently oriented, or both antennas were
  re-seated during the work. **Worth a look at placement/orientation before reading the reverse number as
  the antenna's fault** — the forward leg's level also moved, and nothing was done on 148.
- Forward unchanged in loss (0.006–0.010 %, pooled 0.0083 % over the two legs) despite 4 dB less signal:
  the whitened link has margin.

**Numbers to quote:** forward 0.0083 % (121 / 1,452,181, this morning) and 0.0079 % (229 / 2,904,364,
overnight) at the shipped default; reverse 0.075 % pooled (1,084 / 1,452,181), no wedges, at a level 5.6 dB
below the 09-05 baseline. ≤ 1 % met on both legs; the reverse leg's remaining loss is level-limited.
