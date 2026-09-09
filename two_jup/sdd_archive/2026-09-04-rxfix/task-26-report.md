# Task 26 — the host delivery-path re-anchor: report

**Desk task. NO BOARD CONTACT at any point.** Nothing in this report was
measured on silicon; every number about the link is quoted from Task 23's
banked analysis, and every number about the fix is from synthetic tests on this
workstation.

Deliverables: `host_app_k5/qpsk_frame.[ch]` (the pure scanner),
`host_app_k5/qpsk_tun.c` (the queued-RX drain cursor + counters),
`host_app_k5/test_rxresync.c` (40 checks), `host_app_k5/Makefile`,
`two_jup/comb/RXFIX_HOSTFIX_PREREG.md` (pre-registration), this report.

---

## 1. The 568 bytes, computed from the parser

### 1.1 The three sizes

| | bytes | words (64 b) | where |
|---|---|---|---|
| logical (host) frame | **1528** | 191 | `F1536_PKT_BYTES`, `qpsk_frame.h`; WPP = 191 |
| air frame (TX transfer) | **3080** | 385 | `F1536_TX_XFER_BYTES`, `qpsk_frame.h` |
| RX carve slot stride | **1528** | 191 | `rx_pump_queued`, `qpsk_tun.c` — `rx_dscan * pkt_bytes` |
| RX DMA transfer | **24448** | = 16 × 1528 | `DMAC_X_LENGTH = rx_multi*pkt_bytes - 1`, `rx_q_submit`; `-M 16` |
| carve SLOT_BYTES | 2048 | | `qpsk_hw.h` under `-DQPSK_CARVE_2MB` — **TX only** |

The 3080-byte air frame and the 2048-byte `SLOT_BYTES` are both red herrings for
this defect. The RX side never sees either: the fabric hands the host the
*decoded* 1528-byte logical frame, and `rx_pump_queued` carves the completed DMA
area at a stride of **`pkt_bytes` = 1528**, not `SLOT_BYTES`. (`SLOT_BYTES` is
the TX slot stride, `tx_slot_stride`.)

### 1.2 Why a lost frame does *not* displace anything

If the fabric drops a whole frame, the byte stream is short by exactly 1528 B —
a whole number of slots. Slot *k* then holds frame *k+1*, the alignment is
untouched, and the cost is **one** slot at the end of the transfer. This is
worth stating because it is the null hypothesis the data rejects: a
whole-frame drop cannot produce a burst.

### 1.3 What does displace: a non-multiple

Let Δ be the net byte-count anomaly in the stream (Δ < 0 = deletion). Frame
starts move to stream offset `k·1528 + Δ`, and the parser reads at
`k·1528`. The phase the parser sees is

```
phase = (-Δ) mod 1528
```

and it is **constant for every frame after the event**, because nothing in the
drain loop ever re-derives the frame boundary — the only re-anchor in the whole
path is the *next DMA transfer*, whose request is hard-gated on the frame-sync
tuser (`request_sync_transfer_start`, rr.v:161, quoted in `qpsk_tun.c`'s
queued-RX header comment).

Task 23 measured phase = **568** on 1,259 of the 1,305 magic-carrying class-1
failures against a 2.3 % chance floor (`FWD_RESIDUAL_0p22.md`, headline table
and Q2; `README_hostlog.md` §3.3 for the floor). Inverting:

```
Δ = -(568) mod 1528  ->  Δ = -960 B  (a 960-byte deletion = 120 words)
              or       Δ = +568 B  (a 568-byte insertion = 71 words)
```

Both give the same host-visible phase; the two are distinguished only in the
fabric, which is exactly the discriminator `FWD_RESIDUAL_0p22.md` proposes for
its next instrument ("whether the byte stream **gained** 568 B or **lost** 960 B").
The subordinate populations fall out of the same formula: 25 failures at 376
(Δ = −1152 B = 144 words) and 14 at 1136 = 2 × 568 (two events stacked inside
one transfer). **Every measured offset is a whole 64-bit word** — 71, 47, 142 —
which is what the byte plane's word-oriented delivery predicts and which the fix
relies on (§3.2).

### 1.4 The frame is split across two slots — the crux

At phase 568 the displaced frame occupies

```
slot i  bytes [568 .. 1528)   960 B  (the header and the first 948 payload bytes)
slot i+1 bytes [0 .. 568)     568 B  (the rest)
```

Its 12-byte header is inside slot *i* — which is why `magic_off` reads 568 — but
**960 of its 1528 bytes are there and 568 are not**. A resync that scans *within
one slice*, which is the literal reading of "scan the slice for the next valid
magic+len+CRC", therefore finds the magic and can **never** validate the CRC. It
would count re-anchors and recover nothing, and would fire the brief's falsifier
("PER unchanged with resync_568 counting → the displaced frames are not
recoverable") for entirely the wrong reason.

The fix must re-anchor a **byte cursor into the contiguous carve**. The slots
are physically adjacent inside one DMA area (`rx_area_virt(area) + i*pkt_bytes`),
so the split frame *is* contiguous in memory — it is only the parser's fixed
stride that pretends otherwise. `test_rxresync` check 1b is the falsifier for
this and is the single most load-bearing test in the file.

### 1.5 Why the cascade is 6–15 frames long — and the boundary Task 23 could not name

Task 23 left this open: *"the near-uniform run-length distribution over 5..17
with a hard ceiling at 17 is what a recovery at a boundary a uniform distance
away looks like, but the boundary was not identified"* (`FWD_RESIDUAL_0p22.md`,
"The class"). **The boundary is the RX DMA transfer, and it is 17 slots because
`-M 16`.**

The deployed daemon runs `./qpsk_tun -G -M ${RXM_EFF} ...` with
`RXM_EFF=${RXM:-16}` (`two_jup/bringup_r2r3.sh:171,174`) and the judged leg's
`meta.txt` records `rxm_148=` / `rxm_146=` **unset**, so `rx_multi = 16`. One
transfer is therefore 16 slices, and a burst runs from the event to the end of
*that* transfer:

| burst position | what it is | slots |
|---|---|---|
| 0 | the CRC-fail at the pins (157/159) | 1 |
| 1 | the frame destroyed at the pins (159/159 MAGIC, 151 with no magic at all) | 1 |
| 2 … end of transfer | displaced, intact, magic at 568 | 14 − j |
| — | the frame straddling the transfer boundary: no host record at all | 1 |

with *j* the slot index at which the event lands, so the run length is `17 − j`
for *j* ∈ 0..15. **Ceiling = `rx_multi` + 1 = 17, which is exactly the longest
run Task 23 measured in the whole live window.**

The mean checks too. Task 23: 1,956 slots / 213 events = **9.183** slots per
event; uniform position-in-transfer over 1..17 predicts **9.0**. Residual in the
fit, stated rather than smoothed: the bins are `1:18, 2:1, 3-4:33, 5-20:161`,
so length-1 (18) and lengths 3–17 (~12.4 each) sit near the ~12.5 a uniform
would give, but **length-2 is 1 observed against ~12 expected** and is not
explained here.

The per-event slot budget closes exactly against the checker (`FWD_RESIDUAL_0p22.md`
Q3, 460 s common window, 143 events):

```
8.59 slots/event = 2.05 (positions 0,1: bad AT the pins -- the checker's 293)
                 + 5.53 (positions 2..: displaced but INTACT -- the 791)
                 + 1.01 (the straddler: no host record at all -- the 145)
```

The middle term is the whole of what a host-side re-anchor can recover, and it
is 64.4 % of the residual.

---

## 2. Why it takes 6–15 frames *today*, in one sentence of code

`rx_pump_queued`'s drain reads slice *n* at `rx_area_virt(area) + n*pkt_bytes`
and, on a decode failure, does `st.crc_drops++; framelog_record_fail(...)` and
moves to slice *n+1* at the same fixed stride. There is no scan, no phase, and
no notion that the failure might be an alignment fact rather than a content
fact. The eager path (step 2) is not a second chance either: it *stops* on a
failure by design ("decode-fail = not yet landed vs corrupt is ambiguous"),
leaving those slices to the drain. So the phase persists until
`rx_q_on_complete()` hands the drain a **new** area, whose transfer began on a
tuser and is aligned again.

---

## 3. The fix

### 3.1 A pure scanner — `qpsk_frame_resync()` (`qpsk_frame.c:181`, contract at `qpsk_frame.h:108`)

```c
int qpsk_frame_resync(const unsigned char *buf, size_t n, int pkt_bytes,
                      int max_shift, unsigned char *out, uint32_t *seq, int *len);
```

Scans `d = 8, 16, …, max_shift` for the first offset at which a **complete**
frame validates, requiring `d + pkt_bytes <= n`. Validation is
`qpsk_frame_decode()` itself, so the accept rule is identical to the normal path
and whitening is handled for free. A two-byte magic pre-filter keeps it cheap:
only candidates whose first two bytes match the (possibly whitened) `0x51 0x4B`
pay for a CRC32 — ~0.047 CRCs per call over a 3,056-byte window of random bytes.
The whitener is frame-synchronous (its PN9 resets at byte 0 of every frame), so
the two expected magic bytes are precomputed once for the whole scan.

### 3.2 Two bounds that are correctness, not tuning

**`max_shift < pkt_bytes`.** A "hit" at exactly `+pkt_bytes` is the ordinary,
perfectly aligned *next slot* — not a re-anchor at all. Allowing it would let
every isolated failure be miscounted as a re-anchor and would corrupt the
statistic the judge leg reads. With the bound, a successful scan can only mean a
genuine sub-frame displacement. (`test_rxresync` 1c.)

**8-byte step (`QPSK_RESYNC_STEP`).** Two independent reasons, both binding:
the RX byte plane delivers whole 64-bit words and every measured displacement is
a whole number of them (§1.3); and `carve_copy_from()` reads the `/dev/mem
O_SYNC` DMA carve with **volatile 64-bit loads**, which fault on ARM64 Device
memory at an unaligned address — a byte-granular re-anchor would SIGBUS on 148
while passing every x86 test. `qpsk_tun.c` already refuses a `pkt_bytes` that is
not a multiple of 8 at startup ("bad -p (need multiple of 8…)"); `rx_resync_try`
re-checks it, and `qpsk_frame_resync` refuses such a geometry outright.
(`test_rxresync` 1d, 1g.)

### 3.3 A byte cursor in the drain — `rx_resync_try()` (`qpsk_tun.c:1667`)

`rx_dphase` (`qpsk_tun.c:1080`) is a byte phase added to the slot-indexed
cursor, so the read address becomes `rx_dscan*pkt_bytes + rx_dphase`. It is 0 —
and the address is then bit-for-bit the historical one — until a re-anchor moves
it. On a parse failure:

1. copy a window of up to `2*QPSK_PKT_BYTES_MAX` bytes from the carve, capped at
   the DMA-written region `rx_multi*pkt_bytes` so nothing beyond it (stale bytes
   from an earlier lap, never zeroed there) can be parsed;
2. scan it (§3.1);
3. on a hit at `d`, move the cursor to `off + d + pkt_bytes` — strictly forward
   of where the plain advance would have put it, so no frame is delivered twice
   and the loop still terminates — and deliver the recovered frame decoded from
   the window copy;
4. when the displaced cursor can no longer fit a whole frame before the
   DMA-written limit, `break` and count `tail_lost` (`qpsk_tun.c:1771`).

**The re-anchor runs *after* `st.crc_drops++` and `framelog_record_fail()`.**
The failing slice is still counted and still classified, so `crc_drop`, the
framelog `fail_class` word, the `failhdr` ring, `magic_off` and every offline
census keep exactly the meaning they had. What changes is only where the cursor
goes next. No on-disk ABI is touched (`qpsk_join.h` and `README_hostlog.md` §3
are unchanged; the `pad` byte stays 0).

**Reset points** — the highest-risk part of the change, because a stale phase
leaking into the next transfer would *cause* loss and read as "the fix made it
worse". `rx_dphase = 0` in `rx_q_on_complete()` (`qpsk_tun.c:1633`, where the
drain is handed a new area) and in `rx_arm_queued()` (`qpsk_tun.c:1569`). Both
are pinned by `test_rxresync` 2d.

### 3.4 Scope, deliberately narrow

Only the **queued** drain (`QPSK_RX_QUEUED=1`, the deployed default) is changed.

* The **legacy** multi drain is byte-for-byte unchanged, on purpose: it is the
  explicit control arm for the FIFO A/B, and changing it would mean future
  RXQ=0 comparisons are no longer against the historical baseline. The same
  helper drops straight in if that is ever wanted.
* The **cyclic** ring (`QPSK_RX_CYCLIC`) is unchanged — off by default, needs a
  different bitstream, and addresses its ring by monotonic sequence rather than
  slot index.
* The **eager** path is unchanged and deliberately gets no re-anchor: its
  failure is genuinely ambiguous between "not yet landed" and "corrupt", and the
  drain already sees every slice it skipped.

`QPSK_RX_RESYNC=0` restores the historical behaviour from the same binary, so
the judge leg has a same-build A/B control.

### 3.5 Cost

The scan runs only on a slice that has already failed to parse, and its whole
cost is one extra window copy out of the (uncached) carve plus a two-byte
compare per 8-byte step. At the judged leg's 0.22 % that is ~0.3 events/s x
3,056 B = ~1 KB/s of extra uncached reads; at the W1 baseline's 8.3 % it is
~316 KB/s. Against the failure mode this file already worries about — the
"~84 ms all-junk drains" the drain-budget comment records — an all-garbage
16-slice drain gains ~16 x 3 KB of uncached reads, well under 1 % of that
figure, and `QPSK_RX_DRAIN_BUDGET` (default 4) bounds it either way because the
budget is charged before the scan runs. No allocation, no syscall, and the
window buffer is a single 3,056 B static rather than stack growth in the pump.

---

## 4. New counters

One new line from `stats_dump()`, printed every `-s` interval and on SIGUSR1.
The `stats:` line itself is **byte-identical**, following the convention the
file already sets for `nakstat` / `rxqstat` / `txgap` ("separate line, not
appended, so the uninstrumented build's stats line stays byte-for-byte what
every existing parser expects").

```
qpsk_tun rxresync: on=1 phase=0 resync_568=0 resync_other=0 resync_fail=0 recovered=0 tail_lost=0
```

| field | meaning | prediction on the judge leg |
|---|---|---|
| `on` | `QPSK_RX_RESYNC` state | 1 |
| `phase` | current cursor phase, 0 = aligned | 0 between bursts |
| `resync_568` | re-anchors at exactly 568 B — **the named defect** | ≈ one per loss event |
| `resync_other` | re-anchors at any other offset (376, 1136, …) | ≪ resync_568 |
| `resync_fail` | scans that ran and found nothing — genuinely corrupt slices | ~ the comb/CRC rate |
| `recovered` | frames delivered from a displaced phase — **the payoff** | ≈ 5.5 × resync_568 |
| `tail_lost` | transfer tails given up (no whole frame before the DMA limit) | ≈ resync_568 |

Neither the new strings nor the new symbols contain `nakstat` or `rxqstat`, so
the `strings | grep -c` fingerprints those deploy/restore gates use are
untouched (verified: 4 and 1, unchanged from the pre-change build).

---

## 5. Tests

`host_app_k5/test_rxresync.c`, **40 checks, 0 failures**, added to `make test`.
It builds with `-DQPSK_CARVE_2MB` so the synthetic carve has the deployed
geometry, and includes `qpsk_tun.c` with `main()` renamed — the same trick
`test_k5.c` / `test_txq.c` use — so the checks drive **the deployed drain
function**, `rx_pump_queued()`, against a fake DMA regfile, not a re-implementation.

The synthetic carve is 16 slices of 1528 B with 960 B deleted from the byte
stream part-way through, i.e. §1.3's Δ.

| group | what it pins |
|---|---|
| 0 | the whitened wire format re-anchors (forked child: `qpsk_whiten_on()` caches process-wide) |
| 1a | a frame at the measured 568 B phase is found and decodes with its own seq/len |
| **1b** | **a one-slice window can NEVER validate the displaced frame** (960 of 1528 bytes present) — the falsifier for §1.4 |
| 1c | a frame at exactly `+pkt_bytes` is *not* a re-anchor |
| 1d | unaligned offsets are not scanned; 568/376/1136 are all whole words |
| 1e–1g | garbage finds nothing; idle frames (len 0) recover; degenerate inputs refused |
| 2a | **clean area: 16 delivered, 0 lost, no scan, no re-anchor** — the cursor change is inert when aligned |
| 2b | resync OFF (historical parser): **11 slots lost from one deletion**, 5 delivered |
| **2c** | resync ON, same bytes: **1 lost, 15 delivered, `resync_568`=1, `recovered`=10, `tail_lost`=1** |
| 2d | `rx_dphase` cleared by both `rx_q_on_complete()` and `rx_arm_queued()` |
| **2e** | **the W1 comb (garbage, magic at offset 64) still classifies as MAGIC/`magic_off`=64, does NOT re-anchor, and gives identical accounting with resync ON and OFF** (3 lost / 13 delivered either way; `resync_fail`=3) |
| 2f | a displacement in the last slot costs 1 frame either way — the bound on the fix |

One modelling note, so the synthetic and silicon numbers are not read as
inconsistent: the synthetic case damages **one** frame (the truncated one), so
the fix takes it from 11 lost to 1. On silicon **two** frames per event are
destroyed at or upstream of the pins before the parser ever sees them, plus one
straddler, so the silicon prediction is ~3 lost rather than 1 (§1.5, prereg §2).

A second detail that mattered: the synthetic frames carry the **full 1516-byte
MTU payload**. The CRC covers only header+payload, so a short-payload frame
survives truncation — its CRC validates off the surviving head and the slot
decodes as if nothing happened. Reproducing Task 23's "position 0 is a CRC-fail
in 157 of 159 bursts" requires reproducing the payload length.

### Existing tests

`make test` is green end-to-end: `test_frame` 578, `test_k5` 89, `test_ber`,
`test_whiten`, `test_seq`, `test_txq` 25, `test_txlog` 25, `test_rxresync` 40 —
0 failures. All were also run against a pristine `git archive HEAD` tree and
give identical results, so nothing regressed.

**One pre-existing breakage was repaired.** `test_k5` did **not build at HEAD**:
commit `0822e3e` turned the ARQ constants `AXR_HOLE_SZ` / `AXR_RENAK` into the
runtime variables `axr_hole_sz` / `axr_renak` in `qpsk_tun.c` without updating
`test_k5.c`. Confirmed pre-existing by building the pristine HEAD tree
(same two errors). The repair is a mechanical rename of the two identifiers in
`test_k5.c` only; the test then passes 89/89. It is unrelated to the resync and
is called out separately in the commit — but without it the `make test` target
this task extends could not be run to completion.

---

## 6. Build and binary

The deployed line (`deploy_daemon_go.sh`, NAKKEEP resolved to
`-DQPSK_ARQ_NAKSTAT` because 148's current binary carries `nakstat:`):

```
gcc -O2 -Wall -DQPSK_CARVE_2MB -DQPSK_ARQ_NAKSTAT -DQPSK_RXQ_STAT \
    -o qpsk_tun qpsk_tun.c qpsk_frame.c qpsk_ber.c qpsk_seq.c qpsk_uio.c
```

| | |
|---|---|
| `strings qpsk_tun \| grep -c nakstat` | **4** (the 148 deploy gate; unchanged) |
| `strings qpsk_tun \| grep -c rxqstat` | 1 (unchanged) |
| `strings qpsk_tun \| grep -c rxresync` | 1 (new line) |
| **md5** | **`023d7bfd6db5706e37465ea0ce7bd967`** |
| size | 97,768 B, ELF x86-64 |

The pre-change build of the same sources at HEAD with the same flags is
`b722021d61970b1aa71127071e87f259` (for a "did the binary change" check only).

`deploy_daemon_go.sh`'s `FILES` list was checked against the change: it carries
`qpsk_tun.c`, `qpsk_frame.c` **and** `qpsk_frame.h`, i.e. all three modified
sources, so a deploy rebuilds the fix rather than linking stale bytes. The
`Makefile` is not in that list, which is correct — the deploy uses an explicit
gcc line, not `make`.

**That md5 is not a deploy fingerprint.** This build is x86-64;
`deploy_daemon_go.sh` compiles on the board and will produce a different
aarch64 md5. Compare sources and flags, never the two md5s.

Everything also builds `-Wall -Wextra -Werror` clean, and `test_rxresync` was
additionally built and run with the full deployed flag set
(`-DQPSK_ARQ_NAKSTAT -DQPSK_RXQ_STAT`) so the `QPSK_RXQ_STAT` variant of the
drain (which re-reads a failing slice) follows the same cursor: 40/40 there too.

---

## 7. Pre-registration

`two_jup/comb/RXFIX_HOSTFIX_PREREG.md`, committed before any deploy.
Headline: **PER ≤ 0.08 %** with events unchanged at ~0.30/s,
`resync_568` ≈ the event count, `recovered` ≈ 5.5 × `resync_568`, and the
fabric-side controls (checker gap events ~3/10 s, checker lost slots ~0.054 %,
r4b witnesses ~0.0314) **unchanged**. Falsifier F1 is the brief's:
`resync_568` counting with PER unchanged means the displaced frames are
corrupted, not merely shifted.

### One finding the controller should see before the leg runs

The brief's "cost per event → ~1 frame" is optimistic, and the derived
prediction is **thinner than the registered bound**. Per event, `2.05` slots are
already unparseable at the decoder pins and `1.01` straddles the DMA transfer
boundary; no host-side change can recover either. The floor is

```
(293 + 145) / 572,901 = 0.0764 %      against a registered bound of 0.08 %
```

— about 5 % of headroom. If the fix recovers 90 % rather than ~100 % of the 791
displaced-but-intact slots, PER lands at 0.0902 % and the registered bound fails
**while the fix is working correctly**. Prereg falsifier **F2** covers exactly
that case and calls it PARTIAL (mechanism confirmed, bound wrong), and P4/P5
measure the mechanism directly without depending on the margin. The bound was
left at the brief's verbatim 0.08 % rather than being widened.

---

## 8. What is still open

* **The fabric-side cause of Δ = −960 B (or +568 B) is untouched.** This fix
  caps the *cost* of an event at what the decoder pins already lose; it does not
  reduce the event rate. `FWD_RESIDUAL_0p22.md`'s proposed `rx_seq_checker`
  event ring — specifically its "byte count since the last frame" field — is
  still the instrument that decides the sign, and therefore whether the fabric
  inserted or deleted.
* **The 8.140 s rate modulation** is untouched and unexplained.
* **The straddler (`tail_lost`)** — ~1 slot per event, 11.8 % of today's
  residual — is recoverable in principle by carrying the tail bytes of one
  transfer across into the next area, but only if the fabric truly emits a
  continuous stream across the transfer gap. That is not established, and it
  would couple two DMA areas that are currently independent. Not attempted.
* **length-2 runs: 1 observed against ~12 expected** under the uniform
  position-in-transfer model that otherwise fits (§1.5).
* **Where in the burst the re-anchor fires is not settled by the banked data.**
  §1.5 assumes position 2, after failed scans on the two head frames, but
  `magic_off` records only the *first* magic in a slice, so position 0's
  `magic_off = 0` does not rule out a second magic at 568 in the same slice —
  under a pure 960-byte deletion the scan on position 0 would succeed
  immediately. Both readings give the same PER floor (the checker's 293
  bad-at-the-pins slots per event is independent of either), and the judge leg
  separates them for free via `resync_fail : resync_568` ≈ 2:1 versus ≈ 0:1 —
  registered as prereg **P12**. Task 23's position 1 ("no frame magic anywhere"
  in 151/159) is not explained by a pure deletion either way, so the burst-head
  model is incomplete here.
* **Recovered frames bypass `rx_raw_tap`.** `rx_resync_try` decodes from the
  window copy and returns without calling the tap, so a `-S` raw-scorer leg
  would miss every recovered frame and get a wrong denominator. Harmless for the
  tun-mode judge leg; run any `-S` leg with `QPSK_RX_RESYNC=0` or wire the tap
  first.
* **`comb_census.py`'s class census will change shape** — ~0.89 failure records
  per lost slot today against ~0.4 after the fix, because the re-anchor skips
  slices that used to be read and recorded and the tail `break` records nothing.
  PER (from `host_seq` gaps) is unaffected. Registered as prereg **P13** so it
  is not read as a broken instrument.
* `QPSK_RXQ_ZEROHDR=1` would leave stale frames at displaced phases in the
  carve and could in principle admit a false re-anchor. The judge leg must run
  with it off (its default, and the state the banked leg was in).
