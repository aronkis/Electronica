# Task 1 (T0a) — host-app instrumentation — report

Plan: `/home/tcollins/.claude/plans/happy-bubbling-owl.md` §T0a.
Status: **complete, desk-only, zero board contact.** All work host-side on this
machine; no ssh to 10.0.0.148/146 at any point.

## What was delivered

| file | change |
|---|---|
| `host_app_k5/qpsk_join.h` | **NEW.** Single-source-of-truth ABI: `struct frame_rec` (48 B, moved here), `struct failhdr_rec` (32 B), `struct txlog_rec` (32 B), `struct qpsk_log_hdr` (32 B), the pure `qpsk_fail_class()` / `qpsk_first_magic_off()` parsers, and `qpsk_join_classify()` (the executable spec for the TX↔RX join). Header-only so the daemon, the host tests (which link only `qpsk_frame.o`) and any scorer agree by construction. |
| `host_app_k5/qpsk_tun.c` | `fail_class` in `frame_rec` (the ex-`reserved` word) at all 6 failure sites; failed-header ring (`QPSK_FAILHDR`, 64k × 32 B); TX log extended to `seq` / `t_submit_ns` / `t_complete_ns` / `gap_ns`, ring raised to 1 M records, one record per **frame**, completion stamped in `tx_reap()`. |
| `host_app_k5/test_frame.c` | `fail_class` truth table + an ABI suite (every struct size and field offset). |
| `host_app_k5/test_txlog.c` | **NEW.** Synthetic txlog + frames.bin round-trip through the documented layouts, join fixture, sentinel discipline. |
| `host_app_k5/Makefile` | `test_txlog` target; `qpsk_join.h` added to every dependency list; `test:` now also **runs** `test_txq` and `test_txlog` (it built `test_txq` but never ran it). |
| `two_jup/comb/README_hostlog.md` | **NEW.** Byte-for-byte layouts for Task 2, the fail-class semantics and caveats, the exact gcc deploy line, the rail conflicts, and the deploy blocker below. |

`host_app_k5/qpsk_frame.c` is **untouched** — the decode contract is unchanged;
`qpsk_fail_class()` re-parses a copy of the slice and never runs on the good path.

## Design points worth carrying forward

* **`framelog_record(crc_ok, seq)` kept** for the 4 successful-decode sites
  (always class 0); the 5 decode-failure sites and the `-B` noisy bucket now
  call `framelog_record_fail(p, pkt_bytes)`, which re-parses, emits the
  framelog record with the class, and appends the raw header to the ring.
  With both sinks off it returns before doing any work.
* **Class 4 overrides 1 and 2, never 3.** A frame whose header parses is a
  bit-error frame, not an alignment loss.
* **`first_zero_off` is anchored on an actual zero byte** — without the anchor
  a 200-byte garbage prefix followed by 1328 zeros reports 53, not 200.
* **`magic_off` added to the failhdr record** — kept, but **informational only**
  (see the review-fix list below): it is not an ALIGNLOSS discriminator and has
  a ~2.3 % chance floor.
* **(superseded) original rationale for `magic_off`** (still exactly 32 B) because
  class 4 is at risk of being a null by construction: ALIGNLOSS shifts zeros to
  the end of the **3080 B air frame**, and the host only sees the 1528 B logical
  slice, so the zero tail can lie outside the window entirely. `magic_off`
  (magic present at a nonzero offset = a shift) is the independent
  discriminator. `class4 == 0` is *not* evidence against ALIGNLOSS — stated in
  the README.
* **TX log is atexit-only.** T1 polls stats (SIGUSR1) every 10 s; writing
  32 MiB there would put ~100 ms of I/O into the loop feeding a TX queue that
  holds ~1.6 ms of air, manufacturing the starvation being measured.
  `QPSK_TXLOG_USR1=1` opts in. Both rings are `memset` pre-faulted at startup
  for the same reason, and are dumped in at most two bulk `fwrite`s, never a
  per-record loop.
* **File headers with magics** (`QTXLOG02`, `QFAILH01`) on the two new files so
  the changed TX-log layout cannot be silently misparsed as the old 16 B
  `"<QIHH"` stream. `frames.bin` deliberately keeps its headerless 48 B layout.
* **SIGUSR2 now rotates all three sinks**, not just the framelog. `capture_r3.sh:218`
  rotates before the measurement window; if the rings had kept their pre-rotate
  contents, `frames.bin` and the rings would span different windows and every
  pre-rotate TX submit would join as `NEVER_SENT` — a false epidemic of the one
  class that drives the decision table to "TX byte-in (T5b)". Pending completion
  stamps are cancelled on rotate so a stale ring index cannot stamp the wrong
  record. README §5.5 additionally tells Task 2 to clip the join to the TX log's
  `t_submit_ns` span (frames.bin is opened `"ab"` and appends across daemon
  restarts; the rings are rewritten whole).
* **Sentinels**: `gap_ns == 0xFFFFFFFF` = not measured (≠ 0 ns) and is a lower
  *bound* estimate; `t_complete_ns == 0` = no completion stamped, **not** never
  sent; `first_zero_off`/`magic_off` have explicit NONE values.

## Verification

Host gcc, `-O2 -Wall -Wextra -Werror`:

* `gcc … -DQPSK_CARVE_2MB -DQPSK_RXQ_STAT -DQPSK_ARQ_NAKSTAT` links clean;
  `strings | grep -c nakstat == 4` on the resulting binary (the 148
  fingerprint survives). Plain `-O2 -Wall -DQPSK_CARVE_2MB` build also clean.
* `./test_frame` — **578 checks, 0 failed** (the pre-existing framing suite plus
  the new fail-class truth table at 1528 B and 280 B and the ABI suite).
* `./test_txlog` — **25 checks, 0 failed** (round-trip + 4-way join fixture +
  sentinels).
* `./test_txq` — 25 checks, 0 failed. This one **includes `qpsk_tun.c`** against
  a fake DMA regfile, so it is real coverage that the `tx_send` / `tx_reap`
  edits compile and run.
* Scratch rotate harness (also including `qpsk_tun.c`): SIGUSR2 resets both
  ring heads and cancels the pending completion stamp — 0 failed.
* Scratch harness (`ringchk`, also including `qpsk_tun.c`, so it exercises the
  real static ring code, not a copy) — **29 checks, 0 failed**: failhdr ring
  wrap-by-3 (oldest 3 evicted, newest last, `WRAPPED` flag, `total`), class/
  onset/magic_off/raw-header contents, txlog per-frame records for both
  `tx_send` and a 3-frame batch, completion stamping for single and batch,
  `gap_ns` on the first record only, stale-completion rejection after a wrap,
  and both file headers on disk.
* `test_k5` is **broken at HEAD** (`AXR_HOLE_SZ`, `AXR_RENAK` undeclared) and was
  already failing before this task — confirmed against `git show HEAD`. Not
  touched.

No DRY deploy through `capture_r3.sh`'s ssh shim was run: that requires board
contact, which this task is forbidden.

## The exact gcc deploy line

```sh
gcc -O2 -Wall -DQPSK_CARVE_2MB -DQPSK_ARQ_NAKSTAT -DQPSK_RXQ_STAT \
    -o qpsk_tun qpsk_tun.c qpsk_frame.c qpsk_ber.c qpsk_seq.c qpsk_uio.c
gcc -O2 -Wall -o qpsk_perf qpsk_perf.c
```

Through `capture_r3.sh` (unedited):
`HOST_CFLAGS='-DQPSK_RXQ_STAT -DQPSK_ARQ_NAKSTAT' ./capture_r3.sh <A|B> -d 600`.

Campaign-close plain rebuild (drops `rxqstat`, keeps the 148 fingerprint):
```sh
gcc -O2 -Wall -DQPSK_CARVE_2MB -DQPSK_ARQ_NAKSTAT \
    -o qpsk_tun qpsk_tun.c qpsk_frame.c qpsk_ber.c qpsk_seq.c qpsk_uio.c
```

## Concerns / handoffs

1. **BLOCKER before the first rig deploy.** `qpsk_tun.c` now `#include`s
   `qpsk_join.h`, and neither `two_jup/capture_r3.sh`'s scp list (~line 106) nor
   `two_jup/comb/deploy_daemon_go.sh`'s `FILES` names it. Both deploys will fail
   at gcc (`BUILD_FAIL`, `capture_r3.sh` exits 1 — loud, but at the worst
   moment). One filename must be added to each list. Both files are outside
   Task 1's ownership.
2. `qpsk_join.h` itself is a new file outside the stated ownership list; it was
   unavoidable because `test_frame.c` links only `qpsk_frame.o` and cannot see a
   function defined inside `qpsk_tun.c`. Task 2's `two_jup/comb/joinlog.py`
   already transcribes exactly these layouts and magics — verified field by
   field; they match.
3. **TX-log layout change breaks two existing parsers** for *new* dumps:
   `two_jup/txlog_gaps.py` and `two_jup/loss_ledger.py:tx_gaps_146()` both
   hardcode the old headerless 16 B `"<QIHH"` record. Old captures are
   unaffected; new ones are detectable by the `QTXLOG02` magic. Owned by Task 2.
4. **Rail conflict, by design**: an instrumented daemon has `rxqstat` count 1,
   so `restore_known_good.sh:65`'s "must be 0 — plain build" fails on every
   instrumented deploy. Ledger each one; plain rebuild at campaign close.
5. **Failhdr ring capacity**: 65,536 failures ≈ 13 min at the forward leg's 8 %
   of ~1250 f/s. A 600 s leg fits; anything longer wraps. Check the `WRAPPED`
   flag before quoting a census. The 1 M TX ring covers 838 s.
6. **`make test` does not currently run to completion**: it stops at the
   pre-existing broken `test_k5`. Use `make test_frame test_txlog test_txq` (or
   fix `test_k5`, which is nobody's task right now).
7. The task text said the TX log dumps "on SIGUSR1/atexit **as today**"; today
   is **atexit-only**, and that is what was kept, with `QPSK_TXLOG_USR1=1` as an
   explicit opt-in for a mid-run snapshot. The reason is in §1 of the README:
   32 MiB of I/O on a 10 s SIGUSR1 poll would starve the modulator being
   measured.
8. `fail_class` is computed on raw wire bytes, so it is meaningless under
   `QPSK_WHITEN=1` — the same pre-existing caveat as `host_seq`. The campaign
   runs `WHITEN=0`.
9. In `-B` mode `crc_ok == 0` does **not** imply `fail_class > 0` (the scorer's
   "fail" is a noisy bit bucket, not a decode failure). The legs run `-G`, where
   the implication does hold.


---

## Review round 2 (coordinator, 2026-09-03) — fixes applied

C logic untouched (comments only), per the review's instruction.

1. **§5.2 BLOCKER deleted.** `qpsk_join.h` is in both deploy lists since
   `437386f` (`capture_r3.sh:108`, `comb/deploy_daemon_go.sh:41`); §5.2 is now a
   one-paragraph "ships with the daemon sources" note.
2. **I-1 `magic_off` claim rewritten** in both the README (§3.3) and the header
   comment: NOT an ALIGNLOSS shift discriminator (the mechanism appends zeros at
   the frame end, it displaces nothing), and it carries a **~2.3 % chance floor**
   (a random 1528 B slice contains `0x51 0x4B` with p ≈ 1527·2⁻¹⁶). Field kept,
   marked informational.
3. **I-2 class-4 semantics documented and the earlier over-caution retracted.**
   `first_zero_off == 0` = an all-zero **carve** slice, i.e. a delivery-plane
   hole (`rx_pump_queued` zeroes the carve before each arm, `qpsk_tun.c:1461/1466`,
   `:1203` cyclic); a real TX ALIGNLOSS gives `first_zero_off > 0`; under
   `QPSK_RXQ_ZEROHDR` only 8 bytes are zeroed so such slots land in **class 1**.
   And `class4 == 0` **is** meaningful evidence — the logical frame is the
   leading 1528 B of the 3080 B air frame, so any frame-losing ALIGNLOSS puts its
   zero run inside the host window.
4. **I-3 `capture_r3.sh` recipe corrected** to
   `HOST_CFLAGS_B='-DQPSK_RXQ_STAT'` (board-B only; `:127` `BCF`, and the
   post-build rxqstat verify at `:140` is gated on it) and to **not** pass
   `-DQPSK_ARQ_NAKSTAT` via `HOST_CFLAGS` (`NAKKEEP` `:119-120` carries it per
   board). 148 gets no `rxqstat` on that path by design; if a run needs it there,
   the manual `strings | grep -c rxqstat` is the only check.
5. **Minors.** `magic_off == 0xFFFF` alias commented (cannot collide: slices are
   ≤ 1528 B); README §5.4 states `QPSK_FRAMELOG` **must** be set whenever
   `QPSK_TXLOG`/`QPSK_FAILHDR` are, because the SIGUSR2 handler is installed only
   inside the `QPSK_FRAMELOG` block (`:3266`) and SIGUSR2 would otherwise kill the
   daemon; new §5.6 gives the memory/tmpfs budget (34 MiB resident, ~70 MiB of
   dumps, `df -h /dev/shm` before T3), the dump-completeness rule
   (`filesize == 32 + 32×n_records`, `frames.bin % 48 == 0`) and the ARQ
   duplicate-`seq` caveat. The class-4 onset anchor was **not** tightened to
   99 % — the review forbade logic changes — so §2 documents the ±10 %-of-tail
   onset tolerance instead, noting the census distinction that matters is
   `== 0` vs `> 0`.
6. **New §5.4.1/§5.4.2 (leg wiring).** On `capture_r3.sh` legs the sinks are
   enabled **only** through `DAEMON_ENV` (spliced verbatim at
   `bringup_r2r3.sh:167`):
   `DAEMON_ENV="QPSK_FAILHDR=/dev/shm/failhdr.bin QPSK_TXLOG=/dev/shm/txlog.bin QPSK_TXLOG_USR1=1 ..."`.
   Documented as a hard requirement, with the note that
   `comb/legrun_go.sh:77` currently **overwrites** `DAEMON_ENV` wholesale and
   would run a leg with no TX log or failhdr ring (Task 3 owns the fix), and a
   pre-flight check on `/proc/<pid>/environ`. `QPSK_TXLOG_USR1=1` is recommended
   on legs — `capture_r3.sh` sends SIGUSR1 exactly once, after the window
   (`:294`), so it costs nothing there and protects the 32 MiB log against
   `pkill -9` by `lock_watchdog` or a `-k` run — and must stay **off** for
   `loopfloor_go.sh`, whose 10 s poll is the case the atexit-only default exists
   for.

Re-verified after the comment edits: `test_frame` 578/0, `test_txlog` 25/0,
instrumented build `-Werror` clean.
