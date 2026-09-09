# Host-daemon instrumentation for the COMB campaign (T0a)

Owner: Task 1 (`host_app_k5/qpsk_tun.c`, `host_app_k5/qpsk_join.h`,
`host_app_k5/test_frame.c`, `host_app_k5/test_txlog.c`, `host_app_k5/Makefile`).
Plan: `/home/tcollins/.claude/plans/happy-bubbling-owl.md` (T0a).

`host_app_k5/qpsk_join.h` is the **single source of truth** for every layout
below. This file is its prose transcription; if the two ever disagree, the
header wins and this file is the bug.

---

## 1. What the daemon now records

Three env-gated sinks, all default-OFF (unset ⇒ one pointer test on the path,
no behaviour change — the same opt-in idiom as `QPSK_WHITEN`):

| env | file | layout | ring | dumped |
|---|---|---|---|---|
| `QPSK_FRAMELOG` | `frames.bin` | 48 B records, **no file header** (unchanged) | none (streamed, `fflush`) | SIGUSR1 flush, SIGUSR2 rotate, atexit close |
| `QPSK_FAILHDR` | `failhdr.bin` | 32 B header + 32 B records | 65,536 (**2 MiB**) | SIGUSR1 **and** atexit |
| `QPSK_TXLOG` | `txlog.bin` | 32 B header + 32 B records | 1,048,576 (**32 MiB**) | **atexit only**, unless `QPSK_TXLOG_USR1` is set |

Memory cost: 32 MiB (txlog) + 2 MiB (failhdr), both `calloc`'d **and memset
pre-faulted at startup** so no page fault ever lands inside `tx_send()` or the
RX drain (a lazily-populated 32 MiB mapping would fault for the first ~1 M
submits, i.e. ~14 min of a run, and would manufacture exactly the TX starvation
this campaign is measuring).

**Why the TX log is not written on SIGUSR1 by default.** T1's `loopfloor_go.sh`
polls stats every 10 s = SIGUSR1 every 10 s. Writing 32 MiB there would put
~100 ms of file I/O into the loop that feeds the modulator, and the TX queue
holds only ~1.6 ms of air (2 transfers). Set `QPSK_TXLOG_USR1=1` only for a run
whose purpose is a mid-run snapshot, and record that it was set.

At the R3 rate (~1250 f/s) the 1 M-record TX ring covers **838 s**, so a 600 s
leg never wraps. The failhdr ring covers 65,536 failures ≈ 13 min at the
forward leg's 8 % of 1250 f/s — **a 600 s forward leg fits, a longer one does
not**; check `flags & 0x1` (wrapped) on every dump before quoting a census.

---

## 2. `fail_class` — what a failed frame failed at

`qpsk_fail_class(const uint8_t *p, size_t n, uint32_t *first_zero_off)`
(header-only, pure, in `qpsk_join.h`) re-parses the slice, mirroring
`qpsk_frame.c:139-173` check-for-check **in the same order**:

| value | name | meaning |
|---|---|---|
| 0 | `QPSK_FC_OK` | magic + len + CRC all good |
| 1 | `QPSK_FC_MAGIC` | `p[0] != 0x51 \|\| p[1] != 0x4B` (or the slice is shorter than 12 B) |
| 2 | `QPSK_FC_LEN` | magic ok, `len > n - 12` |
| 3 | `QPSK_FC_CRC` | magic + len ok, CRC32 mismatch |
| 4 | `QPSK_FC_ZEROTAIL` | **would have been 1 or 2** *and* the slice has a ≥ 90 % zero suffix — the ByteBitShifter ALIGNLOSS signature |

Precedence rules Task 2's census must reproduce:

* magic is checked before len, len before CRC (`class N` = "decode would have
  returned −1 at check N");
* class 4 **overrides** 1 and 2, and **never** overrides 3. A frame whose
  header parses is a bit-error frame, not an alignment loss, however many
  zeros follow it.

`first_zero_off` is the smallest offset `k` with `p[k] == 0` such that
`p[k..n)` is ≥ 90 % zero and at least 32 bytes long, else `0xFFFFFFFF`
(`QPSK_FZO_NONE`). It is filled in **regardless of class** — a class-3 frame
with a zero tail is still informative. The `p[k]==0` anchor makes it the *onset*
of the zero region: without it, 200 bytes of garbage followed by 1328 zeros
would report 53, not 200.

**Onset tolerance.** Because the criterion is a ≥ 90 % *average* over the
suffix, the reported onset can sit up to ~10 % of the tail length early or late
relative to a visually obvious boundary when the zero region is impure. Treat
`first_zero_off` as accurate to roughly ±10 % of `(n − first_zero_off)`, not to
the byte; the distinction that matters for the census is `== 0` vs `> 0`
(see below), not the exact value.

### Caveats you must not lose

* **`class4 == 0` IS meaningful evidence against a frame-losing ALIGNLOSS.**
  (This retracts an earlier over-cautious note in this file.) The logical frame
  occupies the **leading** 1528 B of the 3080 B air frame, so an alignment loss
  severe enough to lose the frame necessarily puts its zero run inside the host
  window. A class-4 count of zero over a full leg is a real null, not a blind
  spot.
* **Class 4 with `first_zero_off == 0` is not a TX event at all — it is an
  all-zero CARVE slice**, i.e. a delivery-plane hole: `rx_pump_queued` zeroes
  the carve before each arm (`qpsk_tun.c:1461/1466` queued, `:1203` legacy `rx_arm`; NOT the cyclic path -- `rx_arm_cyclic`/`rx_pump_cyclic` `:1256`/`:1314` never zero the carve, so an all-zero carve slice cannot arise under `RXCYC_A=1`), so a slot the DMA never filled reads back as 1528 zero bytes. A real TX
  ALIGNLOSS always gives `first_zero_off > 0` (the frame starts correctly and
  degenerates part-way). Split the class-4 census on `first_zero_off == 0` before
  attributing anything.
  Under `QPSK_RXQ_ZEROHDR` only the first **8 bytes** of each slot are zeroed
  (`carve_zero_hdr`, `:1438-1442`), so an unfilled slot then lands in **class 1**
  (magic bad, stale non-zero tail), not class 4 — check which mode the leg ran.
* **`crc_ok == 0 ⇒ fail_class > 0` does not hold in `-B` mode.** The `-B`
  scorer logs `crc_ok = (bucket == QBER_CLEAN)`; a noisy-bucket frame can still
  have a parseable header, giving `crc_ok=0, fail_class=0`. In the tun/echo
  modes (`-G`, what the legs run) the implication does hold.
* `fail_class` is computed on the **raw wire bytes**. With `QPSK_WHITEN=1` they
  are whitened and every class is meaningless — exactly the pre-existing caveat
  on `host_seq`. The campaign runs `WHITEN=0`.
* **Index failures by record position, never by `host_seq`**: a magic-bad frame
  logs a garbage seq word.

---

## 3. Binary layouts (byte-for-byte)

All little-endian, naturally aligned, no padding beyond what is shown.

### 3.1 `frames.bin` — 48 B/record, NO file header (unchanged)

```
off  size  field              python
  0     8  t_mono_ns          <Q
  8     8  t_real_ns          <Q
 16     4  host_seq           <I
 20     4  crc_ok             <I     1 = good
 24     4  reg_packets        <I     0x104
 28     4  reg_biterr         <I     0x108
 32     4  reg_rstcs          <I     0x150
 36     4  reg_cfc            <I     0x154
 40     4  reg_adcforensic    <I     0x15C
 44     4  fail_class         <I     WAS `reserved` (always 0)
                                      -> 48 B, struct "<QQIIIIIIII"
```

The record size, field order and offsets are **unchanged**; only the
previously-always-zero `reserved` word now carries the class. Every existing
parser keeps working and reads `fail_class == 0` on pre-campaign captures.

### 3.2 File header for the two new files — 32 B, `struct "<8sIIQII"`

```
off  size  field        notes
  0     8  magic        b"QFAILH01" / b"QTXLOG02"
  8     4  rec_bytes    32
 12     4  n_records    records that follow
 16     8  t_dump_ns    CLOCK_MONOTONIC at the dump
 24     4  total        total events seen (> n_records => ring wrapped)
 28     4  flags        bit0 = QPSK_LOGF_WRAPPED (oldest events lost)
```

Records follow immediately, **oldest first**.

### 3.3 `failhdr.bin` — 32 B/record, `struct "<QIIBBH12s"`

```
off  size  field            notes
  0     8  t_mono_ns        same clock as frame_rec.t_mono_ns (join key)
  8     4  host_seq         RAW p[4..7] -- garbage for a magic-bad frame
 12     4  first_zero_off   zero-tail onset, or 0xFFFFFFFF = none
 16     1  fail_class       1..4
 17     1  pad              0
 18     2  magic_off        first 0x51 0x4B offset, or 0xFFFF = none
 20    12  hdr[12]          the 12 raw header bytes of the slice
```

`magic_off` is **informational only**. It is NOT an ALIGNLOSS discriminator:
the modelled mechanism shifts zeros in at the frame **end**, it does not
displace the header to a later offset, so a nonzero `magic_off` is not evidence
of a shift. It also has a **chance floor of ~2.3 %** — the probability that a
random 1528-byte slice contains the two-byte sequence `0x51 0x4B` somewhere
(1527 × 2^-16). Treat any `magic_off` rate at or below a few percent as noise;
it is worth recording only because a *large* excess would be a genuinely new
observation. `0xFFFF` means "not found" and, because a slice is far shorter than
65,535 bytes, cannot collide with a real offset. Records are appended in the same order as the
corresponding `frames.bin` failures, so the *k*-th failed `frames.bin` record
(counting from the end, back at most `n_records`) is the *k*-th-from-last
`failhdr.bin` record. **That positional shortcut is a convenience, not a
contract** — it holds only within one daemon lifetime with both sinks enabled
from the start (see §5.5). `t_mono_ns` is the safe join key.

### 3.4 `txlog.bin` — 32 B/record, `struct "<QQIIIHH"`

```
off  size  field            notes
  0     8  t_submit_ns      CLOCK_MONOTONIC just after DMAC_SUBMIT
  8     8  t_complete_ns    CLOCK_MONOTONIC at tx_reap; 0 = never stamped
 16     4  seq              header seq word of the submitted frame
 20     4  gap_ns           txgap_note's gap, or 0xFFFFFFFF = NOT MEASURED
 24     4  slot             tx_slot counter (monotonic, not modulo)
 28     2  inflight         queue depth BEFORE this submit
 30     2  spins            polled-mode 100 us spins waiting for a slot
```

**One record per TRANSMITTED FRAME**, not per transfer: `tx_send()` writes one,
`tx_send_batch()` writes `n` (only the first of a batch carries a `gap_ns`).

Sentinel discipline — three ways to get the analysis wrong:

* `gap_ns == 0xFFFFFFFF` means **not measured**, not "0 ns". `txgap_note()`
  only computes a gap when the queue was empty after the reap
  (`inflight_after_reap == 0`); otherwise no silence is observable. Do not
  average the sentinel into anything.
* `gap_ns` is an **estimated lower bound** on fabric-visible silence
  (`now − (prev_submit + prev_frames × frame_period)`, clipped at 0), not a
  measurement of silence.
* `t_complete_ns == 0` means **no completion was stamped** (still in flight at
  the dump, or the ring record had already been overwritten when the reap
  happened). It does **not** mean the frame was never sent. Only the *absence
  of a record* means never-sent.

### 3.5 Layout change vs. the pre-campaign TX log

The old dump was a **headerless** stream of 16 B `"<QIHH"` records
(`t_mono_ns, slot, inflight, spins`). Two existing parsers still assume that
and must be updated (they are outside Task 1's file set):

* `two_jup/txlog_gaps.py` (`REC = struct.Struct("<QIHH")`)
* `two_jup/loss_ledger.py`, `tx_gaps_146()` (`R = struct.Struct("<QIHH")`)

New dumps are detectable by their `QTXLOG02` magic; old captures on disk are
unaffected and should keep being read with the old struct.

---

## 4. TX ↔ RX join

`qpsk_join_classify()` in `qpsk_join.h` is the **executable spec**; the Python
in `two_jup/comb/` must agree with it, and `host_app_k5/test_txlog.c` pins it
against a fixture.

```
NEVER_SENT             (1)  no submit record for that seq in the TX board's txlog
SENT_NOT_DECODED       (2)  submitted, but no crc_ok==1 frames.bin record for it
DECODED_NOT_DELIVERED  (3)  decoded (crc_ok==1) but the payload never reached
                            the consumer (tun / qpsk_perf sequence set)
OK                     (0)  submitted, decoded and delivered
```

Order matters: the TX log is the authority on what was sent, so a seq with no
submit record is `NEVER_SENT` even if the RX decoded a frame carrying that seq
(a garbage header whose seq word aliased). With no delivery evidence
(`delivered == NULL`) class 3 collapses into `OK` — say so in the write-up
rather than reporting the class as absent.

**Clip the join to the TX log's time span** (§5.5): an RX frame whose
`t_mono_ns` falls outside `[txlog.t_submit_ns.min(), .max()]` is UNJOINABLE and
must not be counted as `NEVER_SENT`.

---

## 5. Deploy

### 5.1 The exact gcc line the deploy must use

Instrumented campaign build, **both boards**, run in `/root/host_app_k5`:

```sh
gcc -O2 -Wall -DQPSK_CARVE_2MB -DQPSK_ARQ_NAKSTAT -DQPSK_RXQ_STAT \
    -o qpsk_tun qpsk_tun.c qpsk_frame.c qpsk_ber.c qpsk_seq.c qpsk_uio.c
gcc -O2 -Wall -o qpsk_perf qpsk_perf.c
```

* `-DQPSK_CARVE_2MB` — required for f1536 (unchanged from `capture_r3.sh:128`).
* `-DQPSK_ARQ_NAKSTAT` — **must be present** or 148's `nakstat` fingerprint
  (`strings qpsk_tun | grep -c nakstat == 4`) is silently lost.
  `capture_r3.sh` carries it over automatically by detecting the string in the
  deployed binary; a hand-rolled deploy must pass it explicitly.
* `-DQPSK_RXQ_STAT` — the queued-RX counters this campaign needs.

Through `capture_r3.sh` (which must not be edited), the recipe is:

```sh
HOST_CFLAGS_B='-DQPSK_RXQ_STAT' ./capture_r3.sh <A|B> -d 600
```

* Use **`HOST_CFLAGS_B`, not `HOST_CFLAGS`.** `HOST_CFLAGS_B` is board-B (146)
  only and is the variable `capture_r3.sh` uses as `BCF` (`:127`); the
  post-build `rxqstat` verification at `:140` is gated on `BCF` matching
  `*QPSK_RXQ_STAT*`, so passing the flag any other way builds it in **without**
  the verify.
* **Do NOT add `-DQPSK_ARQ_NAKSTAT` to `HOST_CFLAGS`.** `NAKKEEP` (`:119-120`)
  already detects the `nakstat:` string in the deployed binary and carries the
  flag over per board; passing it globally would also add it to 146, changing a
  board that must stay as deployed.
* Consequence: on this path **148 does not get `-DQPSK_RXQ_STAT`** (that is
  deliberate — 148 rebuilds to a functionally untouched binary). If a run needs
  it on 148, deploy 148 with `two_jup/comb/deploy_daemon_go.sh`, and note that
  `capture_r3.sh` has no automatic check for it there: the **manual
  `strings | grep -c rxqstat` below is the only verification for 148**.

Post-deploy verification on **148**, every time:

```sh
strings /root/host_app_k5/qpsk_tun | grep -c nakstat   # must be 4
strings /root/host_app_k5/qpsk_tun | grep -c rxqstat   # 1 while instrumented,
                                                       # 0 on a capture_r3.sh leg
md5sum /root/host_app_k5/qpsk_tun
```

### 5.2 `qpsk_join.h` ships with the daemon sources

`qpsk_tun.c` `#include`s `qpsk_join.h`, so it must be copied to the board with
the rest of the sources. It is already in both deploy lists
(`two_jup/capture_r3.sh:108` and `two_jup/comb/deploy_daemon_go.sh:41`, added in
`437386f`); any new deploy path must include it or the on-board gcc fails with
`qpsk_join.h: No such file or directory`.

### 5.3 Rail conflict at campaign close

`two_jup/restore_known_good.sh:65` asserts

```
rxqstat : $(strings .../qpsk_tun | grep -c rxqstat)  (must be 0 -- plain build)
```

An instrumented daemon **fails this rail by design** (the count is 1). Ledger
it for every instrumented deploy and, at campaign close, rebuild plain on both
boards:

```sh
gcc -O2 -Wall -DQPSK_CARVE_2MB -DQPSK_ARQ_NAKSTAT \
    -o qpsk_tun qpsk_tun.c qpsk_frame.c qpsk_ber.c qpsk_seq.c qpsk_uio.c
```

then re-check `nakstat == 4` and `rxqstat == 0` on 148.

### 5.4 Runtime env for a leg

```sh
QPSK_FRAMELOG=/dev/shm/frames.bin \
QPSK_FAILHDR=/dev/shm/failhdr.bin \
QPSK_TXLOG=/dev/shm/txlog.bin \
  qpsk_tun ...        # then SIGUSR1 to flush/dump, SIGTERM for the final dump
```

**`QPSK_FRAMELOG` must be set whenever `QPSK_TXLOG` or `QPSK_FAILHDR` is.** The
`SIGUSR2` handler is installed only inside the `QPSK_FRAMELOG` block
(`qpsk_tun.c:3266`); without it SIGUSR2 keeps its default disposition and
**terminates the daemon**, and the rings would never be rotated in step with
`frames.bin` (§5.5).

#### 5.4.1 Enabling the sinks on a `capture_r3.sh` leg — hard requirement

`capture_r3.sh`/`bringup_r2r3.sh` set `QPSK_FRAMELOG` themselves, but they have
no knowledge of the two new sinks. `bringup_r2r3.sh:167` splices the caller's
`DAEMON_ENV` verbatim into the daemon launch line, and that is the **only** way
the rings get enabled on a leg:

```sh
DAEMON_ENV="QPSK_FAILHDR=/dev/shm/failhdr.bin QPSK_TXLOG=/dev/shm/txlog.bin QPSK_TXLOG_USR1=1"
```

Append any other knob (e.g. `QPSK_RX_DRAIN_BUDGET=...`) to the **same** string —
`DAEMON_ENV` is a single pass-through variable, so anything that sets it
wholesale drops the sinks. `two_jup/comb/legrun_go.sh:77` currently overwrites
`DAEMON_ENV` with just the drain-budget knob and would therefore run a leg with
**no TX log and no failhdr ring**; Task 3 owns that fix. Treat "the three sink
variables are present in the daemon's `/proc/<pid>/environ`" as a pre-flight
check for every leg.

#### 5.4.2 `QPSK_TXLOG_USR1=1` on legs, atexit-only on the loopback floor

`capture_r3.sh` sends `SIGUSR1` **exactly once**, after the window, to flush the
loggers before pulling artifacts (`:294`). So on a leg `QPSK_TXLOG_USR1=1` costs
one 32 MiB write outside the measurement window — nothing — and buys real
protection: the atexit dump is lost if the daemon is `pkill -9`'d (the
`lock_watchdog` path, or a `-k` keep-link-up run that never exits cleanly), and
the TX log is the one artifact with no other copy.

Do **not** set it for `loopfloor_go.sh`: that script polls stats every 10 s, and
32 MiB of I/O per poll inside the loop feeding a 2-transfer (~1.6 ms) TX queue
would manufacture the very starvation T1 measures. There, atexit-only.

`SIGUSR1` = stats + framelog flush + failhdr dump (cheap).
`SIGUSR2` = **rotate all three sinks**: truncate+reopen `frames.bin` and reset
both rings, so the three files always describe the SAME window. This matters
because `capture_r3.sh:218` sends SIGUSR2 before the measurement window so the
pulled `frames.bin` is the steady-state post-heal window only; if the rings kept
their pre-rotate contents the join would see TX submits with no framelog
counterpart and score them `NEVER_SENT` — a false epidemic of exactly the class
the T3 decision table is most sensitive to. The rings are dumped whole, oldest
first, on every dump.

### 5.5 Window alignment — read this before joining

* `frames.bin` is opened `"ab"` (**appends across daemon runs**); the two rings
  are rewritten whole on each dump. If a run reuses the same `/dev/shm` paths
  after a daemon restart (bringup between legs, a keeper relaunch), `frames.bin`
  can span two runs while the rings hold only the last. `t_mono_ns` is
  CLOCK_MONOTONIC (board uptime) and stays comparable across a restart, so:
  **clip the join to `[txlog.t_submit_ns.min(), txlog.t_submit_ns.max()]`;
  frames outside that span are UNJOINABLE, not never-sent.**
* `loopfloor_go.sh` already `rm -f`s all three paths before starting the daemon
  (safe). `legrun_go.sh` goes through `capture_r3.sh`, which relies on the
  SIGUSR2 rotate above.
* T0c suggestion: per-run filenames (`failhdr_<ts>.bin`, `txlog_<ts>.bin`,
  `frames_<ts>.bin`) remove the hazard entirely.

### 5.6 Budgets and completeness checks

* **Memory / tmpfs budget.** Resident: 32 MiB (txlog ring) + 2 MiB (failhdr
  ring) = **34 MiB** per instrumented daemon. On `/dev/shm`: `txlog.bin` up to
  32 MiB, `failhdr.bin` up to 2 MiB, `frames.bin` ~48 B × frames (a 600 s leg at
  ~1250 f/s ≈ 36 MiB) — call it **~70 MiB of dumps**, on top of `pair.iq` and
  the daemon log. **Run `df -h /dev/shm` on both boards before T3** and again
  after; a short write is silent.
* **Dump completeness rule.** A `failhdr.bin` / `txlog.bin` is complete iff
  `filesize == 32 + 32 × n_records` with `n_records` read from the header.
  Anything else is a truncated pull or a full tmpfs — discard it, do not score
  it. For `frames.bin`: `filesize % 48 == 0`.
* **Duplicate TX records are expected.** The ARQ retransmit path submits the
  same frame again, so one `seq` can appear in several `txlog` records. The join
  is a set membership test (`seq` present ⇒ sent), but any per-frame TX timing
  statistic must decide explicitly whether to take the first or the last submit.

---

## 6. Host-side tests

```sh
cd host_app_k5
make test_frame test_txlog && ./test_frame && ./test_txlog
```

* `test_frame` — the framing contract suite plus the new `fail_class` truth
  table (good→0, magic→1, len→2, crc→3, garbage+zero-tail→4, the
  magic‑before‑len‑before‑crc ordering, class‑4 precedence over 1/2 but not
  over 3, `first_zero_off` onset, `magic_off` for a shifted magic, and the
  sub‑32‑byte zero run that must **not** count as a tail) and an ABI suite
  pinning every struct size and field offset above.
* `test_txlog` — writes a synthetic `txlog.bin` + `frames.bin` through the
  layouts above, reads them back, and checks the four join classes on a
  fixture, plus the sentinel discipline (`gap_ns` NONE vs measured,
  `t_complete_ns == 0` is not never-sent, an empty TX log makes everything
  never-sent rather than silently reporting 0 % loss).

Use that explicit target list: `make test` currently **stops at `test_k5`**,
which is broken at HEAD for reasons unrelated to this work (`AXR_HOLE_SZ` /
`AXR_RENAK` undeclared) and was already failing before Task 1 touched anything.
`test_txq` and `test_txlog` are wired into the `test:` rule so they run once
`test_k5` is fixed.
