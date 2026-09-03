# tap_replay_study -- real R3 IQ tap through the FIXED-POINT f1536 netlist byte RX

**Question:** does the hardware modem's 26-frame decode burst (hunt tap
`two_jup/r3cap/hunt_auto_20260731_211829/pair.iq`) reproduce when the captured
samples are replayed through the bit-true fixed-point netlist receiver?

## Setup (what was actually run)

- **DUT netlist:** `obj_byte_f1536/Vwrap_byte__ALL.a` -- the Jul 25 Verilator
  build of the **f1536** `TxRxComposite` netlist (the one that passed the
  f1536 S1B gates, `s1b_f1536_rot*`; verified geometry: 191 x 64-bit words =
  1528 B per delivered frame, 12333 sym/frame, interleaver BRAMs 32768-deep).
  The driver `../sim_byte_iq_perframe.cpp` was linked directly against that
  archive (`perframe_f1536` here) -- **no codegen was run**.
- **PITFALL FOUND:** `obj_byte_iq/obj_byte_iq_f1536` (Jul 29) is **mislabeled**
  -- its compiled model internals are byte-identical in shape to the 240k/k5
  build (`obj_byte_iq`): 16-word (128 B) frames, k5-size RAMs. It is NOT an
  f1536 netlist. Likewise the CURRENT `s1_rtl/hdlsrc` (regenerated 2026-07-31
  09:02) is the k5 geometry ("f1536 span=1120 symbols" in
  `checkhdl_gate_240k5_byte.log` == k5 span), so `build_iq_instruments.sh`
  today would build the WRONG geometry.
- **Drive:** `rx_input_select=1`, raw int16 I/Q fed 1-per-4-clks
  (f1536 rail = 16 clk/sym, sps=4; calibrated from the S1B f1536 gate run:
  2,368,036 clks / 147,995 syms), `vphase=0`, `rstcs_end=8400`, `skip=0`,
  no DC removal, no zero-splice needed (tap contains no zero samples),
  rotation 0 (the RX phase-ambiguity corrector locks at any quadrant --
  pilot swept rot 0/90/180/270, identical results).
- **Verdict:** per delivered frame, host-contract CRC
  (`host_app_k5/qpsk_frame.c`: magic 'QK', CRC32 over 12 B header + payload,
  whitening OFF as in the capture) -- `score_frames.py` / `aggregate.py`.
- **Chunking:** frames replayed in overlapping chunks (8 warm-up frames each,
  cold-start acquisition takes ~1 frame; warm-up + chunk-tail overlap
  regions are scored from the neighboring chunk).

## Frame-index anchoring (important for reading the numbers)

`pair.iq` sample-frame `k` = samples `[k*49332,(k+1)*49332)`. The sim shows
frame `k` carries TX seq `53577+k`. The hardware FRAMELOG (`frames.bin`,
anchored by `reg_packets - CAP_START pkts`) is offset **+89..90 frames** from
the sample capture (the iio capture started ~72 ms after the CAP_START
register read), so FRAMELOG indices were re-anchored by **seq**, not by
`reg_packets`.

Hardware ground truth mapped into pair.iq frame coordinates:

| event | FRAMELOG evidence | pair.iq frames |
|---|---|---|
| isolated loss A | seq 53877-53878 missing | k = 300-301 |
| isolated loss B | seq 53909 missing (raw hdr seq 0) | k = 332 |
| **the burst** | seq 54174..54199 missing (26 frames); 25 garbage host reads all within ONE frame period (t=0.5733-0.5741 s); `reg_packets` frozen at +708/709 | **k = 597..622** |

Note the burst's host-side signature (25 reads of random garbage in <1 ms,
packet counter frozen) already looks like a delivery/DMA seam event, not 26
bad air frames -- the replay below tests the air/decode leg directly.

## Result

(TO BE FILLED by aggregate.py after the chunk runs complete)

## Files

- `perframe_f1536` -- IQ perframe driver linked vs the preserved f1536 archive
- `run_region.sh F0 F1 ROT [JOBS] [WARM]` -- chunked region replay
- `score_frames.py PFX` -- CRC verdict for one run prefix
- `aggregate.py` -- merge chunks -> `framemap.csv` + failure-run summary
- `chunk_*_{frames,rxw,res}.txt`, `framemap.csv` -- raw evidence

## 2026-08-12 -- k=609 coverage hole closed

k=609 was the one burst frame never scored by any chunk: it was
chunk_540_609's undelivered payload tail (sim tail is only ~60k clks), and it
sits in chunk_610_679's warm-up region (w0=602), which is never scored. A new
dedicated chunk `chunk_605_620_r0` (payload 605..620, w0=597, 8 warm-up
frames, same pair.iq + md5, rot=0, provenance stamped) was run to score it
directly. Sim wall time: ~4.8 min single job.

**Verdict: hole closed -- k=609 decodes clean.** crc_ok=1, words=191,
decoded seq=54187. Sanity re-check k=605..615: all crc_ok=1, 191 words,
seq contiguous (54183..54193). aggregate.py (provenance check passed) folded
the chunk into framemap.csv: the hardware burst region **k=597..622 is now
26/26 CRC-clean in the replay** -- the bit-true fixed-point receiver decodes
every frame of the 26-frame hardware loss burst from the captured air
samples, confirming the burst was NOT an air/decode failure (consistent with
the host-side delivery/DMA-seam signature: 25 garbage reads in <1 ms with
reg_packets frozen).
