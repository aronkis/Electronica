
================================================================================
CAMPAIGN CHECKPOINT — 2026-08-25 ~00:0x (overnight, operator away until 7am EST)
================================================================================
HEADLINE: the forward loss class is NAMED. **146's TX BYTE-PLANE DATAPATH corrupts
~10% of frames regardless of content or load; bypassing it (fabric ROM) is clean.**
And the float baseline is DELIVERED: an ideal receiver recovers 81/81 frames with
0/995,652 bit errors from the same air the hardware runs on (Es/N0 ~29 dB).

VERIFIED ON HARDWARE TONIGHT (all committed through the Task-5 synthesis commit):
 1. Byte-source ladder on 146 (forward air): ROM clean (0 comb events/28,213 frames);
    idle-only byte-DMA 9.33% corrupt; saturated tun 10.62% (8,332/78,461, CP95UL
    10.837%). => TX byte-plane datapath, content-independent.
 2. A3 float-vs-hardware on one 124 ms air window: float 81/81 frames, 0 errors,
    mapping [1 3 2 0] identified at margin 12,068, snrEst 29.0 dB; hardware same
    window 305 errs/151 frames = 8.2e-5 (now classed IMPLEMENTATION -- thermal is nil
    at 29 dB). G4 held.
 3. Tap verdict: e49c011b (08-13 image, on 148 after rails rollback) tap HEALTHY
    (22.04 MHz / env 0.539). Ramp bracketed to the 08-13..08-22 flash sequence.
 4. tgenrx flash 9259cfade5b4: readback rail PASSED, health gate FAILED (fsync=4225
    garbage-lock, wcnt=0), auto-rollback to e49c011b verified, no retry per rail.
    TGEN GPIO witness clean. Signature resembles the arm-class, unproven.
RETRACTION-FREE NIGHT: no earlier conclusion was overturned tonight; one wedge-
contaminated leg pair was discarded BEFORE interpretation (delivery-health gate added:
idle_rx>500/s verified pre-count; that gate is now part of the leg discipline).

RIG STATE AT CHECKPOINT: 148 = e49c011b7a75 (08-13 lineage, tap WORKS, BEATFIX absent
-- it was on fe5bd8a4fe19, re-flashable, both banked). 146 = TMR 433fd8dab393 untouched.
Link came up GATE_DIR=A try 1 all night (146 RX still arm-lottery ~515 f/s, irrelevant
forward). capture_r3 -k left daemons up after leg B; watchdogs restarted+verified after
each session. NO FLASH EVENTS remain authorized; nothing pending on the rig.

FLOAT INSTRUMENT (k5_240/float_baseline_f1536.m): G1-clean, VALIDATED_ESN0_FLOOR_DB=10,
snrEstDb + errPosProfile emitted, precorrthresh=0.8 + preCorr-rank calibration (both
bypassable), gate catch filtered (proven by deliberate-error injection). First real-air
validation PASSED tonight (A3).

NEXT (operator decisions, options recorded in SINGLES_CAMPAIGN.md): the fix path for
146's TX byte plane -- offline TMR-vs-lean netlist diff of the TX byte plane first;
any 146 flash is a first-of-campaign event needing its own rails discussion. Also
parked: ramp source in the 08-13..08-22 lineage; BEATFIX re-flash if wanted; reverse
re-baseline.
