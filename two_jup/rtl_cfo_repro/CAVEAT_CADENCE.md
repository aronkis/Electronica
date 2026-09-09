# CAVEAT — this directory's absolute numbers were produced at cadence 4  [sim]

**Filed 2026-09-03** from the COMB32 SRO desk simulation
(`two_jup/comb/COMB32_SRO_SIM.md` §5). **No file in this directory has been altered.**
This is a caveat on reuse, not a retraction of the campaign's conclusions.

## The finding

`TxRxComposite.v:480` (built netlist,
`jupiter_240k5_byte/s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback/`) ties the receiver's valid
input high in **both** input modes:

```verilog
assign IntValidConst_out1 = 1'b1;
assign RxValidConst_out1  = 1'b1;
assign MUX_RxValid_out1 = (rx_input_select == 1'b0 ? IntValidConst_out1 : RxValidConst_out1);
```

The receiver therefore consumes one sample per `enb_1_2_0` beat (clk/2) **regardless of
`adc_validIn`**. The ADC port is a rate-adapting capture register (`AdcCap*` / `AdcRT*` /
`AdcStab*`), not a valid-gated stream. Consequently a replay driver that raises
`adc_validIn` once every 4 clocks presents **each ADC sample to the DSP chain twice**.

The `_res.txt` files here record `cadence=4`, and `sim_byte_taps.cpp` (the driver that
produced them) defaults to it.

## Measured effect, with a 4-samples-per-symbol stimulus

| cadence | `Rate_Handle` FIFO pushes/frame | pops/frame | occupancy | packets decoded |
|---|---|---|---|---|
| **4** (as used here) | 23,895 | 23,895 | 0↔1, unstable | **0** |
| **2** (correct) | **12,333** | **12,333** | flat at 5 | locks, 164 of 165 |

12,333 pushes = 12,333 pops per frame is the arithmetic the design is built to satisfy
(12,333 symbols per frame at 4 samples/symbol). At cadence 4 the effective oversampling
seen by the symbol synchronizer is 8, not 4.

## What this does and does not mean

- **Do not reuse the absolute numbers in `res/*.txt`** — `packets`, `biterr`, `cfc_est`,
  `nrxw` — without a cadence-2 re-run. They were measured on a duplicated sample stream.
- The **relative** structure of the CFO sweep (the ordering and symmetry of the signed
  CFO points, all measured under the same cadence) is not directly challenged here; it
  was simply not re-measured.
- The **stimulus** in this directory (`gen_cfo_stim.m` and its `.iq` output) is not
  implicated. The defect is in the replay driver's valid cadence, not the waveform.
- Nothing here bears on the H-1 conclusions drawn from silicon captures.

## How to re-run correctly

Use the cadence-2 driver added by the SRO campaign:

```sh
B=jupiter_240k5_byte/rtl_sim/obj_byte_sro/Vwrap_byte_sro
$B rx <stim.iq> <nsamp> 8400 <out_prefix> 2 0
#                                          ^ ^ cadence=2, vphase=0
```

`sim_byte_taps.cpp` also accepts a cadence argument; pass 2.

Cross-reference: `two_jup/comb/COMB32_SRO_SIM.md` §5 ("Method caveat: cadence").
