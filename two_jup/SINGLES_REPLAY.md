# Netlist replay of the forward corrupt singles (r3cap/singles_reread)

**Question:** do the forward-direction corrupt singles — single frames delivered
CRC-corrupt by board 148's RX at the -M16 DMA-boundary cadence — reproduce when
the same air samples are replayed through the bit-true fixed-point f1536
netlist, or do they decode clean (⇒ corruption enters at/after the byte/DMA
seam in 148's fabric)?

**Verdict: they decode CLEAN. 12 of 12 scoreable hardware-corrupt seqs decode
CRC-good (191/191 words) in the netlist from the same captured samples.
The corruption is NOT in the air signal or the demod path — it enters at or
after the byte/DMA seam in 148's fabric.**

Off-hardware analysis, 2026-08-12. All sims: `perframe_f1536` (the preserved
Jul 25 bit-true f1536 netlist archive) driven by
`jupiter_240k5_byte/rtl_sim/tap_replay_study/run_region.sh` (provenance-stamped),
run in `tap_replay_study/singles_replay/` (symlinked, so no prior chunk files
were touched). No netlist was rebuilt.

## Inputs

- `two_jup/r3cap/singles_reread/pair.iq` — 8,000,000 complex int16 samples
  captured on 148 (forward RX), 162 frames at SPF=49332 (~130 ms),
  md5 in the `.prov` sidecars.
- `two_jup/r3cap/singles_reread/frames.bin` — 148 framelog, 48-byte records per
  `two_jup/frame_taxonomy.py` DTYPE.
- `two_jup/r3cap/singles_reread/regs_cap.txt` — CAP_START/CAP_END anchors
  (t=1786568120.9476 / 1786568121.1391, pkts 0xC182/0xC271).

## 1. Hardware ground truth (frames.bin)

In the candidate window (seq 31990..32260) the hardware stream has exactly 20
missing-or-corrupt seqs, all at the -M16 DMA-boundary cadence (reg_packets
0xXX{0,1}{E,F} — every 0x10/0x20 packets):

- **12 corrupt singles**: good S-1, one CRC-fail record whose decoded header
  seq is garbage, good S+1 —
  S ∈ {31999, 32032, 32040, 32065, 32073, 32098, 32139, 32163, 32171, 32196,
  32229, 32237}.
- **4 two-frame events**: S delivered with garbage header + S+1 delivered with
  *intact* header but CRC-fail — (32007,32008), (32106,32107), (32131,32132),
  (32204,32205).
- **1 extra garbage record** (header seq=0, crc_ok=0) between good 32148 and
  good 32149, with **no** seq hole — this is a real on-air event, see below.

The hardware `reg_biterr` counter jumps 300–860 counts across each corrupt
event vs a bursty 0–120/frame baseline elsewhere (link meta: crc=92%).

## 2. Netlist replay (whole capture)

`CAP=…/singles_reread/pair.iq ./run_region.sh 0 161 0 3` — three parallel
chunks (0-69, 70-139, 140-161, 8 warm-up frames, rot=0), plus two
re-alignment chunks (80-100, 115-135) to cross-check. Provenance stamped from
this pair.iq in every `.prov`. Wall time: ~13 min for the full-capture region
(3 chunks parallel), ~6 min for the re-alignment pair; ~20 min total.

Seq anchor (decoded directly from netlist payloads): capture frame k carries
seq 32064+k for k ≤ 84, and 32063+k for k ≥ 85 — the -1 step is an inserted
non-seq-bearing frame slot at k≈84.5 (precedent: ANCHOR_REDERIVED.md k=300/330).
Capture covers seq 32065..32227; scoreable (warm-up/tail excluded per the
chunk-tail trap) 32066..32223.

### Per-seq verdicts for the hardware-corrupt seqs

| hw-corrupt seq | event type | in capture? | netlist verdict | alignments |
|---|---|---|---|---|
| 31999, 32007, 32008, 32032, 32040 | single/pair | before capture start | — | |
| 32065 | single | k=1 = first deliverable frame | **unscorable** (cold-start acquisition frame; no warm-up possible) | |
| 32073 | single | k=9 | **CRC-GOOD**, 191w, seq decoded 32073 | 0-69 |
| 32098 | single | k=34 | **CRC-GOOD**, 191w | 0-69 |
| 32106 | pair (garbage hdr) | k=42 | **CRC-GOOD**, 191w | 0-69 |
| 32107 | pair (intact hdr, crc fail) | k=43 | **CRC-GOOD**, 191w | 0-69 |
| 32131 | pair | k=67 | **CRC-GOOD**, 191w | 0-69 and 70-139 |
| 32132 | pair | k=68 | **CRC-GOOD**, 191w | 0-69 and 70-139 |
| 32139 | single | k=75 | **CRC-GOOD**, 191w | 70-139 and 80-100 |
| 32163 | single | k=100 | **CRC-GOOD**, 191w | 70-139 |
| 32171 | single | k=108 | **CRC-GOOD**, 191w | 70-139 |
| 32196 | single | k=133 | **CRC-GOOD**, 191w | 70-139 and 115-135 |
| 32204 | pair | k=141 | **CRC-GOOD**, 191w | 140-161 |
| 32205 | pair | k=142 | **CRC-GOOD**, 191w | 140-161 |
| 32229, 32237 | single | after capture end (k=166, 174) | — | |

**12/12 scoreable hardware-corrupt seqs decode CRC-good.** Since capture-path
artifacts could only *add* errors, netlist-clean on a hardware-corrupt frame is
one-sided-safe evidence: those frames were intact on air.

### Controls (hardware-good seqs)

Best-of-alignment coverage 32066..32223 (158 seqs): **157 decode CRC-good,
1 fails** — seq 32149, the frame immediately after the on-air TX mute (below),
which the hardware did decode. No other netlist failure survives a second
chunk alignment.

## 3. The one real on-air event (and a replay caveat)

- Samples 4,163k–4,167k (~4,400 samples, k≈84.4) sit at 0.7× RMS — a real
  ~72 µs TX mute/dip. The netlist deterministically delivers an **all-zero
  191-word frame** in that slot at both alignments; the hardware logged the
  seq=0 garbage record at exactly this point (between 32148/32149). This slot
  is the -1 seq-offset step. It is an air/TX event, unrelated to the -M16
  singles cadence.
- **Alignment-dependent recovery transient:** in the first pass,
  chunk_70_139 failed 32149-32158 (intermittent) and 32185-32191
  (intermittent). Re-running the same samples at different chunk alignments
  (chunk_80_100, chunk_115_135) decodes **all** of 32150-32162 and
  32172-32197 clean — those failures were netlist loop-state transients
  seeded by the mute + warm-up alignment, not sample corruption (frames were
  not byte-identical across alignments; hardware biterr shows no distress
  there). Only 32149 fails at every alignment tried. This is the
  reverse-PER caveat to keep in mind when reading single-alignment replays.

## 4. Conclusion

At every scoreable -M16-cadence corrupt-single (and corrupt-pair) event, the
bit-true f1536 netlist recovers the frame perfectly from 148's own captured
air samples: correct 'QK' header, correct seq, correct length, CRC-32 passes,
full 191 words. The demodulated air signal at those frames is healthy; the
hardware's corruption (garbage or partially-corrupt frame bytes with intact
early header in the pair events) is introduced at or after the byte/DMA seam
in 148's fabric. The hardware biterr spikes (300-860) at these events are
therefore measured on already-corrupt post-seam data, not evidence of demod
distress. Float-EVM (MATLAB) probing was unnecessary — no hardware-corrupt
seq failed in the netlist.

## Files

- `jupiter_240k5_byte/rtl_sim/tap_replay_study/singles_replay/` —
  `chunk_{0_69,70_139,140_161,80_100,115_135}_r0.*` (sims + `.prov`
  provenance), `compare_singles.py` (merge + hw cross-reference),
  `framemap_singles.csv`, `region_run.log`.
- Hardware event extraction: `two_jup/frame_taxonomy.py` `read_frames` over
  `r3cap/singles_reread/frames.bin` (this doc, section 1).
