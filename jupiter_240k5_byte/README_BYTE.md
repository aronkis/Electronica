# jupiter_240k5_byte — K5 QPSK modem + byte-DMA data plane with IN-FABRIC FEC Tx encoding

Clone of `jupiter_240k5` (240 ksym, sps=8, K=5 [35 23] FEC Rx TB=25, pre-coded-ROM
BIST Tx, no-scramble/no-descramble air, taps 0x150/0x154/0x15C, T8.3 AGC En10
±32 + adc_forensic, **T8 RATE FIX (masters 270227a/bf1baad/0129ce4): Rsym =
1.92e6 with sps 8 puts the Transmitter rail at 15.36e6 model = enb_1_2 =
1.92 Msps physical = TRUE 240 ksym** — the S1-era 0.96e6 rail was the
half-rate ur-bug; the v6 cadence_patch_ipcore is retired, Rx lands natively
on the right rung; G1 passed both directions on image t8final 494122c1) PLUS the
byte-DMA data plane: host byte ingress → **in-fabric K=5 FEC encode** → air;
air → K=5 Viterbi decode → host byte egress.

Entry point: `assemble_jupiter_240k5_byte.m` (donor phases 0..2.12 verbatim,
then byte phases 2.13–2.16). Gates: `sim_byte_gate_k5.m` (model),
`run_netlist_gates.sh` (checkhdl → makehdl → S1 ROM regression → S1B byte
netlist gate). Vivado build NOT launched from this kit yet (see "Vivado
completion" below).

## Data plane

```
 host byte DMA (64-bit AXIS @30.72M)
   └─ ByteWordBuffer (qpskByteWordBuffer, 2-deep, registered tready)   [composite]
       └─ RT → 15.36M rail → Transmitter/Input Data/ByteBitShifter (qpskByteBitShifter)
           └─ FEC Tx Encoder K5 [NEW, this kit]
               TxGateK5      : beat framing at the msggen chart cadence
                               (enable=enb, reset=Cast To Boolean, start=MG/3);
                               beats 0..1083 = info (shifter bit), 1084..1087 =
                               zero tail, infoValid tags exactly those beats
               ConvEncK5     : K=5 [35 23] rate-1/2, shift register advances
                               ONLY on infoValid (anti-zero-stuff gate, the
                               qpsk-fec-zed-encoder-fix class); encReset
                               (frame start) zeroes state BEFORE the bit-0
                               shift (reset-then-advance) => per-frame 'term'
                               encoding bit-exact to convenc
               TxInterleaveK5: ping-pong 136x16 block interleaver (write 2
                               bits/infoValid beat row-linear; read PREVIOUS
                               frame with legacy perm r*16+c) + the 64-bit
                               PN9 filler (T8 fix 6bcaa62: x^9+x^5+1 seed
                               all-ones; the 64-ones filler's DC dwell was
                               notched by the TX LOL tracking cal) on beats
                               2176..2239 => ONE-FRAME latency
           └─ BitMux (Switch u2~=0): u1 = encoded byte branch,
                                     u2 = extBitSel (= tx_data_source @0x158),
                                     u3 = pre-coded K5 ROM (BIST)  → txData
 Rx: demod → deint(136x16) → Viterbi(K5,TB25) → RxAlign → Capture Data Bits
   └─ recBit/recBitValid/recStart taps (byte_rx_overlay_k5) → ByteSerializer
      (qpskByteSerializer, WORDS_PER_PACKET=16) → BeatGate → byte-RX DMA
```

## Bit/byte contract (k5_240/PACKET_K5.txt)

* Host Tx frame = 35 x uint64 words (2240 bits): the 1084-bit info field
  (120-bit 'ADI Hello World' MSB-first/char + 964-bit rng(9002) PN pad in the
  BIST vectors) occupies bits 0..1083; bits 1084..2239 are don't-care fill.
  Packing: byte-0-first, MSB-first within each byte, LSB byte first in the
  word (`qpskByteBitShifter` / ByteDmaRegisters.pack convention).
* Air frame (both branches, identical contract): 2176 coded bits
  (interleaved, perm r*16+c) + the 64-bit PN9 filler (golden_k5.mat
  payload(2177:2240), T8 fix 6bcaa62 -- NOT the legacy 64 ones) = 2240
  payload bits after the 13-symbol Barker preamble; 1133 symbols/frame.
* Byte-RX packet = 16 x uint64 = first 1024 of the 1084 decoded info bits
  (128 B/frame); trailing 60 info bits are DISCARDED by the serializer's
  start-reset (WORDS_PER_PACKET=16 — deliberate delta from the donor's 35).

## Deliberate deltas from the donors (documented decisions)

1. **tx_data_source at AXI x"158"** (donor bytetx used x"11C"): 0x11C is this
   kit's `dbg_sentinel` (fec_counters_overlay) — collision. 0x150/0x154/0x15C
   are taken by the taps/forensic registers, so 0x158 (left reserved by
   T8.3) is the byte-mode select. 0 = ROM pre-coded BIST, 1 = byte-encoded.
2. **ByteSerializer WORDS_PER_PACKET=16** (donor 35): the K5 recovered stream
   is the DECODED 1084-bit info field, not the 2240-bit raw payload.
3. **One-frame Tx latency on the byte branch**: air frame N carries
   encode(byte frame N-1). Causal necessity — the 136x16 interleave's first
   read (beat 136) needs coded bit 2160, which is produced at write beat 1080
   of the same frame; a same-frame read is impossible, so the fec_dut
   ping-pong scheduling (read the previous frame's bank) is kept. The first
   frame after (re)start is a zeros+filler garbage frame; steady state is
   bit-exact. The model/netlist gates account for this (golden required from
   the first golden frame onward, allowance <= 3 aligned / <= 8 rotated).
4. **Encoder reset-then-advance refinement** vs fec_zed_noscr3's
   clear-instead-of-shift: on the start beat the state is zeroed and THEN
   bit 0 is shifted in. The donor was only bit-exact because 'A' starts with
   a 0 bit; this form is bit-exact to convenc for arbitrary info and
   self-heals state corruption at every frame boundary. Verified against
   convenc (random trials) and by the host-contract self-check in
   `sim_byte_gate_k5.m` (host encode == ROM payload).
5. **Model-sim RxAlign retune (harness-only)**: the shipped RxAlign '+41'
   skip is the NETLIST-measured gated-Viterbi latency (RXROOT E8, cap_out
   golden in RTL loopback). The BEHAVIORAL comm Viterbi block leads the RTL
   pipeline by exactly 16 deintValid beats, so `sim_byte_gate_k5.m` patches
   its HARNESS COPY to '+25' (diagnosed from cap_out 0xA6120492 = the exact
   LSB-first pack of info bits 16..47). The kit model/RTL keep 41; the
   netlist gate re-proves golden alignment on the real RTL.

## HW bring-up findings (2026-07-08, board 148 = image 447caa2073)

Localized on silicon by manual devmem DMA (no daemon). Two settled results:

1. **The byte-RX fabric datapath is CORRECT** (the earlier "byte_rx delivers
   zero data / fabric bug" diagnosis is FALSIFIED). Proofs, ROM source
   (0x158=0), internal loopback:
   * BIST bit_errors (0x108) LOCKS (0x75 flat while packets 0x104 climb).
     Capture_Data_Bits taps the SAME nets as the ByteSerializer
     (QPSK_Rx_dataOut/validOut/startOut) -> recBit is right at the Receiver.
   * A manual rx-DMA one-shot SYNC capture returns the 16 golden RX words
     BYTE-EXACT (rx_words_golden.hex), byte-0 = "ADI Hell", word-aligned via
     tuser -- with byte_ctrl_gpio=1 AND =0. So IP byte_rx_data pin ->
     rx_byte_breakout -> rx_byte_dma S2MM -> DDR all work.
   All passing gates (model oracle, S1B netlist, sim_byte.cpp) stop at the IP
   pin; the BD + S2MM egress + host are exercised ONLY on hardware.

2. **The host daemon was the "zeros" bug**: the K5 byte contract is ASYMMETRIC
   -- TX transfer = 35 words / 280 B (one 2240-bit air frame; the bit-shifter
   word-aligns byte->air on the per-transfer wordFirst/tlast), RX packet = 16
   words / 128 B. qpsk_tun used pkt_bytes=128 for BOTH -> 16-word TX transfers
   -> misframed air. Fixed in host_app_k5/qpsk_tun.c (tx_xfer_bytes=280,
   zero-padded, stored via aligned 64-bit words -- glibc memset's DC ZVA faults
   on the O_SYNC non-cacheable DMA buffer). Verified: byte source (0x158=1) +
   the golden 35-word TX frame pushed cyclically -> cap_out GOLDEN 0x04922282 +
   the 16 golden RX words.

**RESOLVED (2026-07-08) -- fixed by `resolver_lookback_fix` (git `8033363`); the
byte plane now carries arbitrary data 99.9% on HW. The diagnosis below is kept as
the root-cause forensics; see "RESOLUTION" at the end of this section.**

_Historical symptom (pre-fix):_ **CONFIRMED MODEL/RTL BUG, sim-reproducible:** the byte->air TX path round-trips
ONLY the golden vector. Arbitrary 35-word frames are content-DETERMINISTICALLY
misframed. Silicon: full QK frame and a golden frame with ONLY word0 swapped to
a QK header BOTH give cap_out=0x231D481C (expected 0x0002ED28A), stable across
re-arms, ~47% bit divergence (misframe, not a few bit errors); golden decodes
bit-exact and deterministic. **The netlist reproduces this EXACTLY**: feeding
the same QK vector through the S1B Verilator harness
(`rtl_sim/tx_words_qk.hex`) yields cap_out=0x231d481c and scrambled byte_rx --
bit-identical to hardware. So it is NOT silicon/drive-specific; it is a logic
bug in the model byte->air path (ByteBitShifter word/bit alignment, the msggen
`start` vs wordFirst coincidence, or the 136x16 ping-pong interleaver frame
boundary). It was masked because EVERY sim/netlist gate (model oracle, S1B
rot0/rot17, sim_byte.cpp) used the SINGLE golden vector; rot17 only rotates the
word phase of that same content. Repro (minutes, free):
```
cd rtl_sim && ./obj_byte/Vwrap_byte tx_words_qk.hex $((100+38*18128)) 0 s1b_qk
# capout=231d481c (want 0002ed28a); s1b_qk_rxw.txt != the QK words
```
Fix path: debug in that harness (dump ByteBitShifter word stream + interleaver
banks on the non-golden frame), fix the overlay, re-gate with BOTH golden AND a
non-golden vector, then rebuild. NOT a host change.

### ROOT CAUSE (2026-07-08, root-caused in the free harness -- NOT a byte-overlay bug)

Instrumented the byte-TX chain (rtl_sim/wrap_byte_dbg.v + sim_byte_dbg.cpp,
taps ByteBitShifter bit / TxGateK5 infoBit,infoValid,frameStart / ConvEncK5
codedPair / TxInterleaveK5 encBit + FecCapture cap_in/cap_deint) and diffed
GOLDEN vs QK vs a PN-random vector. Findings, stage by stage:

* ByteBitShifter delivers the CORRECT info bits for ALL vectors (golden
  "ADI Hello", QK "QK"+len+seq, random) -- shifter/gate CORRECT.
* ConvEncK5 encoder output matches an offline reference for ALL -- encoder CORRECT.
* Interleaver output (tx_air) is well-formed for ALL.
* GOLDEN: received cap_in == tx_air, cap_deint == enc_coded, cap_out golden. Round-trip identity.
* QK & RANDOM: received cap_in == **rot90(tx_air)** EXACTLY (all 32 bits), for
  BOTH -- i.e. the QPSK constellation is received rotated by exactly 90 degrees.
  cap_deint != enc_coded, cap_out wrong. (rot90 = the sole corruption; nothing
  else differs -- confirmed by exhaustive 4-rotation check.)

=> ROOT CAUSE: the RX resolves the QPSK 4-fold PHASE AMBIGUITY to the wrong
quadrant (a constant +90 degrees) for every non-golden payload; golden alone
lands on 0 degrees. This is in the BASE modem RX (Phase Ambiguity Estimation &
Correction / carrier recovery), NOT the byte-TX overlays (proven correct above)
and NOT the FEC. The frame sync is fine (clean, exact rotation -- not garbage).
The data scrambler is cleanly BYPASSED on both TX (EnableScrambling=1'b0) and
RX, so this is not a scramble/whitening mismatch (a PN-random payload fails
identically to structured QK -> whitening cannot fix it). Golden "works" only
because its specific bit pattern happens to resolve to quadrant 0; the modem
was originally validated (OTA G1, S1B, model oracle) with that single golden
vector. Historical repro vectors: rtl_sim/tx_words_qk.hex, rtl_sim/tx_words_rand.hex.

### RESOLUTION (2026-07-08, git `8033363` -- `resolver_lookback_fix`)

Fixed by a base-modem change: `resolver_lookback_fix` restores the phase-ambiguity
estimator's look-back window to the preamble, giving robust preamble-based
full-quadrant resolution instead of the golden-only quadrant-0 accident. Validated
in the free harness on BOTH golden and non-golden vectors, then hardware-proven:
the byte plane carries arbitrary (non-golden) data at **99.9% on HW** (merge
`8033363`, "byte plane carries arbitrary data 99.9% on HW"). The fix is integrated
by `assemble_jupiter_240k5_byte.m` and is present in the shipped rxfix image
(BOOT.BIN md5 `8d6b82ff...`). The S1B rot0/rot17 gates pass and the golden path is
re-gated (still cap_out=0x04922282), so both golden and arbitrary payloads decode.

## Known HW-risk class (why the sim gates are necessary but not sufficient)

The ZedBoard history (docs_session/qpsk-two-board-link-state.md 2026-06-29):
infoValid-GATED encoders passed behavioral + iverilog netlist sims yet
radiated a CW TONE on the xc7z020 (Vivado retiming/silicon artifact of the
changed encoder cell; the sims do not model the SSI/DAC sample fill). This
kit targets the Jupiter ZU3EG (the K=7 fec_jupiter build with in-fabric
encoder+Viterbi met timing and ran), but the first HW bring-up MUST verify a
streaming metric (magCV / spectrum) BEFORE trusting BER, per that finding.

## Gates

* `assemble_jupiter_240k5_byte.m` — hard pre-synth structural gates, incl.
  gate (c) INVERTED vs the donor: the Tx FEC encoder is REQUIRED and its
  infoValid-gated advance structure is asserted, plus byte ports, WPP=16
  literal, workflow byte maps at x"158", sentinel x"11C" preserved, byte RD.
* `sim_byte_gate_k5.m` (model level, internal loopback): four runs —
  A aligned/golden info, B rotated word phase (idx0=18), C ALT-pad mux
  discriminator (air == encode(altInfo) != ROM proves the air really flows
  bytes→encoder, not a stuck BitMux), D tx_data_source=0 ROM regression.
  Oracles: (a) modulator symbol stream bit-exact vs rom_words_70_k5.txt,
  (b) cap_out == 0x04922282 + bit_errors steady, (c) byte_rx = the 16 golden
  info words/frame. Writes SIM_BYTE_GATE_K5.txt.
* `run_netlist_gates.sh` (netlist level): `checkhdl_gate_240k5_byte.m`
  (checkhdl 0 errors + makehdl → s1_rtl + cadence_rtl_patch + HDL greps),
  S1 ROM regression (iverilog `rtl_sim/tb_tx_240k5.v`, ext ports tied off →
  s1_analyze_240k5.m → S1_GATE.txt), S1B byte gate (Verilator
  `rtl_sim/wrap_byte.v` + `rtl_sim/sim_byte.cpp`, aligned rot=0 + rotated
  rot=17 → s1b_analyze_byte.m → S1B_GATE.txt).

## Vivado completion (NOT run from this kit — post-T8 merge)

`hdlworkflow_loopback.m` is already retargeted at the byte RD
(`AnalogDevices.jupiter.plugin_rd_rxtx_byte`, 'JUPITER (RX & TX, BYTE DMA)',
ReferenceDesignParameter incl. multiple=2 preserved) with all 10 byte port
mappings inserted. The build will fail at the Create Project step exactly like
the parent kit (wrong add_ip path) — the completion Tcl (`complete_and_byte.tcl`,
to be derived from this kit's `complete_and_gather.tcl`) must do, in ONE
Vivado session on `hdl_prj_jupiter_composite/vivado_ip_prj`:

1. **Template insert**: the `vivado_insert_ip_TEMPLATE.tcl` body with the
   corrected `update_ip_catalog -add_ip ./ipcore/TxRxCompo_ip_v1_0.zip` path
   (AXI4_Lite clk/resetn, M07_AXI, 0x9D000000 seg, the rx/tx sync_input/
   sync_output data+valid connects, IPCORE_CLK/RESETN, system_top.v).
2. **9 byte pin connects** — the byte RD's BD cells `byte_breakout` (Tx side)
   and `rx_byte_breakout` (Rx side) to the modem IP:
   * `byte_breakout/byte_data[63:0]  -> TxRxCompo_ip_0/byte_data`
   * `byte_breakout/byte_valid       -> TxRxCompo_ip_0/byte_valid`
   * `byte_breakout/byte_first       -> TxRxCompo_ip_0/byte_first`
   * `TxRxCompo_ip_0/byte_ready      -> byte_breakout/byte_ready`
   * `TxRxCompo_ip_0/byte_rx_data[63:0] -> rx_byte_breakout/byte_data`
   * `TxRxCompo_ip_0/byte_rx_valid   -> rx_byte_breakout/byte_valid`
   * `TxRxCompo_ip_0/byte_rx_last    -> rx_byte_breakout/byte_last`
   * `TxRxCompo_ip_0/byte_rx_user    -> rx_byte_breakout/byte_user`
   * `rx_byte_breakout/byte_ready    -> TxRxCompo_ip_0/byte_rx_ready`
   (exact pin names per the plugin's addInternalIOInterface connections).
3. **NO GATHER** (T8 final, master f105b95): the BD keeps the STOCK
   `sync_output -> axi_adrv9001/dac_1_data_*` wiring. The gather is DELETED
   from the flow (with the rail raised to 1.92M the stock forwarding is
   rate-correct). Base the completion Tcl on the parent kit's
   `complete_stock_t8.tcl` (copied into this kit) = template insert +
   validate + synth/impl/bitstream/bootgen, ADDING ONLY the 9 byte pin
   connects of step 2. Also note `hdlworkflow_loopback.m` no longer calls
   `cadence_patch_ipcore` (commented out -- the v6 cadence patch must NOT
   run on the natively-correct rung).
4. Pre-synth BD assertion gate, then synth + impl + write_bitstream + bootgen.
