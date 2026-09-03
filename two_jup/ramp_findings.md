# Task 1 stop-gate: RX1 IQ "ramp" characterisation

Date: 2026-08-31
Image on 148 at time of test: `0f203cf887d3` (confirmed via `md5sum /boot/BOOT.BIN | cut -c1-12`
on-board; the README's "Currently flashed" annotation still names `fe5bd8a4fe19` and is stale —
not corrected here since it's out of this task's scope).

## Tooling available

`iio_readdev`, `iio_attr`, `iio_info` are all present at `/usr/bin/` on 148. `xxd` is **not**
installed on this image (the plan's draft probe script assumed it and silently produced empty
output); `od` and `hexdump` are present and were used instead.

`iio_info` shows the rx-lpc device as buffer-capable with two int16 channels:

```
iio:device3: axi-adrv9002-rx-lpc (buffer capable)
    voltage0_i:  (input, index: 0, format: le:S16/16>>0)
    voltage0_q:  (input, index: 1, format: le:S16/16>>0)
```

## Exact command used

```
ssh root@10.0.0.148 'cd /tmp && iio_readdev -b 4096 -s 65536 axi-adrv9002-rx-lpc voltage0_i voltage0_q > /tmp/rxdump2.bin'
ssh root@10.0.0.148 'od -An -td2 -w4 /tmp/rxdump2.bin'
```

(`-s 65536` = 65536 int16 words = 16384 I/Q sample pairs; `od -td2 -w4` decodes as signed 16-bit,
4 bytes per row = one (I,Q) pair per row.)

`iio_readdev` exited 0 with no stderr and produced a 262144-byte file (65536 words × 4 bytes),
confirming the buffer path itself works end-to-end (device open, buffer alloc, DMA, read) on
this image.

## Representative sample (signed decimal, I then Q per row)

```
    261   7197
     37   7453
     65   7453
    361   7454
    268   7454
     44   7710
     72   7710
    352   7711
    261   7711
     36   7967
     65   7967
    105   7936
     12   7936
     44      0
     72      0
    360      1
    269      1
     44    257
     73    257
    353    258
    261    258
     36    514
     65    514
    369    515
```

Full 65536-word capture recorded at `two_jup/rampprobe/20260831_163103/` (device listing, tool
probe) and reproduced in this run's transcript; the Q column above is representative of the
whole buffer, not cherry-picked (checked head, middle, and tail of the file — see wraparound
below, taken from mid-buffer).

## Classification

**Q channel**: a clean, monotonically incrementing counter. It steps by 256 then by 1
alternately (net +257 every two samples), i.e. `7197 → 7453 → 7454 → 7710 → 7711 → 7967 → …`.
At the top it wraps: `…7967, 7936, 0, 1, 257, 258, 514, 515, …` and then resumes the identical
+257-per-two-samples climb from zero. This is not modulated data — it is a free-running digital
counter with no dependence on RF input, occasionally re-basing near its wrap point.

**I channel**: also cycles through small, slowly-drifting integer values in lockstep with the Q
counter's period (four-sample groups: `261,37,65,361 → 268,44,72,352 → 261,36,65,105 → …`),
consistent with a second counter/LFSR-style test-pattern generator rather than RF-derived data —
it is neither zero/constant nor plausible modulated I/Q (no broadband, roughly-Gaussian,
zero-mean scatter).

Both channels are synthetic, deterministic, input-independent digital test patterns. This
matches the **monotonically incrementing counter** case: a test pattern injected at (or very
near) the ADC interface, upstream of anything the DDR-capture design's packer/DMAC would touch.

## Verdict: **PROCEED**

The ramp is reproduced cleanly and immediately via the standard IIO buffer path on the currently
flashed image, with a working `iio_readdev`/DMA/buffer chain (exit 0, correct byte count, no
errors). Its signature — deterministic counters, no RF dependence, clean wraparound behaviour —
is exactly what a digital test-pattern injected at the ADC/JESD interface produces. The evidence
does not implicate the packer or DMAC: those components handled the buffer transfer correctly
(right size, no errors, no hang), they just faithfully passed through synthetic counter data
because that is what's arriving from the ADC path upstream of them on this lineage.

This is consistent with, not contradictory to, the existing README caveat. The plan's assumption
— that RX1's ADC source is the fault, and that feeding RX2's packer from internal fabric signals
instead bypasses it — is **not falsified** by this probe. Task 2 may proceed.

(This run does not reach a "plausible modulated I/Q" verdict, so no README correction is filed.)

## Rig / link health

- Board 148 image confirmed: `0f203cf887d3`.
- `qpsk_tun` and `lock_watchdog` confirmed running on **both** 148 and 146 after the probe.
- 0x104 (frame counter) rate measured post-probe: `p0=0xE07AB2 p1=0xE092F2` over 5 s ⇒ **1241
  frames/s**, consistent with the expected ~1245 f/s baseline.
- No writes were made to any control/config register; only IIO buffer reads and a DRA read of
  0x104 were performed. `bringup_r2r3.sh` restore was not needed and was not run.
- Rig acquired/released cleanly across several short holds (`ramp_probe`, `ramp_probe_diag`,
  `ramp_probe_capture`, `ramp_probe_capture2`, `ramp_probe_healthcheck`, `ramp_probe_final`);
  mutex directory confirmed empty (`released`) after each hold ended.
