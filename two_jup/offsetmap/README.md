# offsetmap/ — how these were produced, and why they are the load-bearing artifact

`tap3_word_to_offset.tsv` and `capin_word_to_offset.tsv` enumerate the capture word produced at
EVERY offset within a frame, for the demod-input and FEC-input instruments respectively. Every
displacement result in §31–§46 is a lookup in one of these.

Both are **injective** (one word per offset, no collisions across 12,320 / 24,640 offsets), so a
hit is unambiguous; chance is ~3·10⁻⁶ for tap 3.

## Regenerating them
```
cd jupiter_240k5_byte/rtl_sim
cp -a s1_rtl_ddrcap s1_rtl_hyp                     # netlist copy, isolated from running agents
verilator --cc --exe --build -O2 -Wno-fatal --top-module wrap_byte_hyp -Mdir obj_hyp \
  -y s1_rtl_hyp/hdlsrc/commhdlQPSKTxRxLoopback -y . wrap_byte_hyp.v sim_hyp.cpp -o Vwrap_byte_hyp
./obj_hyp/Vwrap_byte_hyp 6 8  > /tmp/hyp_sel6.txt   # symbol domain (tap 3 / ddrcap sel 6)
./obj_hyp/Vwrap_byte_hyp 9 10 > /tmp/hyp_sel9.txt   # bit domain (cap_in)
```
Then rebuild the tables (see the header line of each `.tsv` for the exact window and packing).

## Two traps these encode
- **tap 3 / selector 6:** 16 CONSECUTIVE `QPSKConstellationValid` strobes, MSB-first,
  symbol = `{sign(I), sign(Q)}`. Anchored at marker **+1** — the §36 skew, confirmed on silicon.
- **cap_in:** the first 32 bits after the FEC `startIn`, LSB-packed, and the bit-domain capture
  packs **16 bits per beat** — a beat is a word, not a bit.

## The rule that governs their use
**A map is witness-specific.** Feeding another witness's words into it manufactures results — §46
did exactly that on its first attempt and produced eight phantom rungs before the scan was redone
one column at a time.
