# Anchor re-derivation from decoded seq (k -> hardware seq), 2026-08-12

Off-hardware analysis. Inputs: `framemap.csv` (this dir, pair.iq-only, post-quarantine),
raw chunk word streams (`chunk_270_339_r0_rxw.txt`, `chunk_294_312_r0_rxw.txt`), and the
hardware FRAMELOG `two_jup/r3cap/hunt_auto_20260731_211829/frames.bin` (primary data,
48-byte records per `frame_taxonomy.py` DTYPE). This doc supersedes the naive anchor
`hardware_seq = SEQBASE + k` (SEQBASE=53577) used in `RESULTS.md` /
`SLICER_REPLAY_FINDINGS.md`; it does not edit those docs.

## Rows used

`framemap.csv`: 492 rows, k = 270..810; k = 351..399 (49 slots) are covered by no chunk
and absent from the map. Excluded from the fit: 8 chunk-tail artifacts
(`delivered=0, words=0`: k = 350, 469, 539, 609, 679, 749, 809, 810) and the 2
delivered-but-CRC-failing slots (k = 300, 330). **Fit used all 482 CRC-good rows.**

## Anchor: seq = k + offset, per contiguous region

Every CRC-good row fits its region offset with **zero residuals** (mismatches = none):

| k range   | offset (seq−k) | CRC-good rows | note |
|-----------|----------------|---------------|------|
| 270..299  | +53577         | 30            | matches the old SEQBASE anchor |
| 301       | +53576         | 1             | after the k=300 zero-frame slot |
| 302..321  | +53577         | 20            | after TX seq skip of 53878 |
| 322..329  | +53579         | 8             | after TX seq skip of 53899–53900 |
| 331..808  | +53578         | 423           | after the k=330 zero-frame slot; holds through the burst |

Discontinuities (change in offset between adjacent decoded slots):

| at k      | jump | decoded evidence | cause |
|-----------|------|------------------|-------|
| 300→301   | −1   | k=299→53876, k=300 slot, k=301→53877 | slot k=300 carries **no seq-bearing frame** (see below) |
| 301→302   | +1   | 53877 → 53879 in adjacent slots | **seq 53878 was never transmitted** (TX-side skip; no intervening slot) |
| 321→322   | +2   | 53898 → 53901 in adjacent slots | **seqs 53899–53900 never transmitted** (TX-side skip) |
| 330→331   | −1   | k=329→53908, k=330 slot, k=331→53909 | slot k=330 carries no seq-bearing frame |

## The two "CRC failures" are ALL-ZERO frames, not decode failures

Reassembling the delivered 1528-byte frames from the raw word streams:

- `chunk_270_339_r0` ord 38 (= k=300) and ord 68 (= k=330): **all 1528 bytes are 0x00**
  (no 'QK' magic, len=0, seq=0).
- Independently confirmed at a different alignment: `chunk_294_312_r0` ord 14 (= k=300,
  between decoded 53876 and 53877) is likewise all-zero, byte-identical.

The netlist delivered a full 191-word frame whose demodulated payload is entirely zero
(capture ran with whitening OFF). This is a deterministic property of the air signal at
those two slots, reproduced bit-exactly at two chunk alignments — not a decision-path
bit-error event.

## Hardware ground truth (frames.bin, primary data)

Delivered host_seq stream over the full replay window 53847..54390 has exactly four
non-unit steps and exactly one crc_ok=0 record:

| record neighborhood (seq / crc / reg_packets / t_mono) | event |
|---|---|
| 53876/1/29305 → **0/0/29336** → 53879/1/29336 (25.7 ms host gap, pkts +31) | "loss A": 53877–53878 undelivered, one zero-header read |
| 53898/1/29337 → 53901/1/29337 (55 us, no gap record) | **undocumented**: 53899–53900 undelivered |
| 53908/1/29338 → **0/0/29338** → 53910/1/29338 | "loss B": 53909 undelivered, one zero-header read |
| 54173/1/29598 → **54174/0/29625** → 24 garbage-seq crc=0 reads (0.9 ms, pkts frozen 29625/29626) → 54200/1/29626 | the burst: 54174 delivered CRC-bad, 54175..54199 undelivered |

The hardware's two zero-header (`seq=0, crc=0`) reads sit exactly where the netlist
decodes the two all-zero air frames. They are the same frames.

## Verdicts

### k=300 (was: "reproduces loss A, seq 53877")

**Refuted as an identification; reclassified.** Under the corrected anchor:

- k=300 is the all-zero air frame between seq 53876 (k=299) and 53877 (k=301). It
  carries no seq; it is the hardware's zero-header read inside the loss-A window.
- **seq 53877 — which hardware lost — decodes CRC-good in the netlist at k=301.**
- **seq 53878 — also counted lost — was never transmitted** (adjacent decoded slots jump
  53877→53879). It is a TX-side seq skip, not an RX loss.

So the netlist does **not** reproduce a decode failure of any hardware-lost seq at loss A.
The k=300 "failure" is the zero-frame itself (the hardware delivered the same zero frame).
The hardware record shows a 25.7 ms host read gap with reg_packets jumping +31 at this
event — a host-side stall signature, consistent with 53877 being air-decodable yet
undelivered.

### k=330 (was: unsupported, near "loss B, seq 53909")

**Resolved; same class as k=300.** k=330 is the all-zero air frame between 53908 (k=329)
and 53909 (k=331) — the hardware's second zero-header read. **seq 53909 — hardware
loss B — decodes CRC-good in the netlist at k=331** (not k=332 as the old anchor had it).
Loss B is therefore also not reproduced as a decode failure.

### The 26-frame burst (was: "seq 54174..54199 = k=597..622")

**Span corrected by one: the burst maps to k = 596..621.** In the burst region the anchor
is seq = k + 53578 (single contiguous region 331..808, no discontinuity anywhere near the
burst), so:

- hardware 54174 (delivered CRC-bad) = k=596 — **netlist decodes it CRC-good**;
- hardware 54175..54199 (undelivered) = k=597..621;
- hardware resumes at 54200 = k=622 (netlist also CRC-good).

Netlist rows k=594..624 are contiguous CRC-good seq 54172..54202 with one hole: k=609
(seq **54187**) is a chunk-tail artifact, never covered by any chunk. Burst verdict is
**upheld and strengthened**: 25 of the 26 hardware-affected seqs (54174..54199 minus
54187) decode CRC-good from the same samples, including 54174 which the hardware
delivered corrupt. The samples are good; the burst is a delivery-side event.

### Undocumented hardware event

53899–53900 undelivered (between 53898 and 53901) appears in no prior event list. The
netlist shows these seqs **were never in the air** (adjacent slots k=321→53898,
k=322→53901): a TX-side seq skip, not an RX or delivery loss. Likewise 53878.

## Net reinterpretation (evidence, not edit, of prior docs)

Every hardware-lost seq in this window that actually existed in the air (53877, 53909,
54174..54199) is decodable by the bit-true netlist from the same samples, except 54187
which is merely uncovered. The two netlist "CRC failures" are all-zero transmitted
frames, delivered as zeros by hardware and netlist alike. On this capture there is **no
demonstrated RX demod/decision-path failure**; the isolated-loss class collapses into
(a) TX zero-frame/seq-skip anomalies at the transmitter and (b) host-side delivery
stalls. This bears directly on `SLICER_REPLAY_FINDINGS.md`'s two-class split and on the
planned hybrid-ladder localisation of k=300 (there is no fixed-point divergence to
localise: the payload is zero in float and fixed alike; the ~11.7° phase step previously
found adjacent to k=300 is consistent with a TX mute/underrun and resume).

Open item unchanged: k=609/seq 54187 needs one `run_region.sh` invocation to close the
burst hole.
