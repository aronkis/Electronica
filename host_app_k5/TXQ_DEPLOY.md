# TXQ_DEPLOY — TX inter-transfer gap witness + idle batching (host-only, 2026-08-28)

## What this is
- **Witness (always on):** a new stats line, printed after every `qpsk_tun stats:` line
  (that line is byte-for-byte unchanged):
  `qpsk_tun txgap: n=<submits> empty=<submits that found the DMAC queue empty> gt20us=<est. silence > 20 us> gt50us=.. gt200us=.. max_us=.. p99_us=.. mean_us=.. idle_batch=<N>`
  Silence is estimated host-side: when a submit finds the queue empty after reap, the
  fabric has been idle since `prev_submit + prev_frames * frame_period`. Lower bound.
- **Mitigation (opt-in):** `QPSK_TX_QUEUED=N` — idle keepalives are batched N air frames
  per MM2S transfer (`tx_send_batch`, TLAST per transfer kept, frames air-aligned at
  `tx_xfer_bytes`), so the single latched transfer covers N frames of air instead of one.
  N=5 is the maximum at F1536 (5 x 3080 B per 16 KB stride); 0/1 = legacy per-frame.
  Data frames are unchanged (per-frame `tx_send`); a data frame waits at most N frame
  periods (~4 ms at N=5) for the queue — acceptable for the PER experiment, note the latency.
  `QPSK_RX_DRAIN_BUDGET` (already in the daemon) bounds the RX drain per loop pass and is
  the complementary knob; try it second.

## Mechanism (see the comment block at tx_send() in qpsk_tun.c)
The axi_dmac latches ONE request ahead (single register set; a SUBMIT while one is latched
overwrites it), so `max_inflight=2` is the hardware maximum and the TX slack is <= one
transfer of air (~0.8 ms per F1536 frame). Any event-loop iteration longer than the
remaining latched air — the S2MM-boundary drain of 16 slices is the recurring one —
starves the fabric's 16-word ByteWordBuffer (> ~20 us) and costs exactly one air frame
(rtl_sim/TXPLANE_SIM_RESULTS.md). Batching idle frames raises the slack to N frames.

## On-board build (both boards, same recipe as docs/setup-prebuilt.rst)
```
cd /root/host_app_k5
cp qpsk_tun qpsk_tun.pre_txq            # rollback binary
gcc -O2 -Wall -Wextra -DQPSK_CARVE_2MB -o qpsk_tun qpsk_tun.c qpsk_frame.c qpsk_uio.c qpsk_seq.c qpsk_ber.c
```
(libc only; no -lm needed — the witness uses integer bins.) Host tests: `make test_txq && ./test_txq` (25 checks).

## Enable
Bring-up: `DAEMON_ENV="QPSK_TX_QUEUED=5" bash bringup_r2r3.sh r3` (the bring-up passes
`${DAEMON_ENV}` into the daemon launch on both boards), or export it before a manual
`./qpsk_tun -G -M 16 -r 15360 -i tun0 -s 5`.

## What to observe (148 on the probe-3 image, decoder-output checker via two_jup/rxchk_run.sh)
1. Witness first, batching OFF: per 60-s window, `gt20us` (this board's TX) should track the
   PEER's fabric bad-magic count for frames this board transmitted. In 148-only internal
   loopback (two_jup/loopchk_run.sh Test A: 5.13 % bad-magic at ~1263 f/s = ~65 events/s)
   the prediction is `gt20us` ~= 3,900 per 60 s window, +-10 %.
   If `gt20us` is ~0 while bad-magic stays ~5 %, the silence is NOT host-side and this
   mitigation will not help — stop and say so.
2. Then `QPSK_TX_QUEUED=5`: `gt20us` -> ~0 and fabric bad-magic -> ~0 in loopback; on air
   the forward bad-magic should drop by ~146's own underrun fraction (the remaining part is
   RF + the RX-side RXQ=0 loss, which is a separate defect).
3. `idle_tx` in the stats line now increments by N per batched transfer (same frame count).

## Rollback
`cp /root/host_app_k5/qpsk_tun.pre_txq /root/host_app_k5/qpsk_tun` and restart via bring-up
without `DAEMON_ENV`. The witness line is harmless if left in place.

## Risks
- Batching changes the TX transfer size the fabric sees (N x 3080 B, one TLAST): the
  ByteBitShifter re-aligns on wordFirst per transfer; frames 2..N stay aligned by the
  385-word cadence (same contract as `tx_send_batch` in -S mode). Verified in the netlist
  only for per-frame transfers today — watch `short/orphan` on the checker.
- #48 wedge class (drain stalls / stale-DDR replay on fresh queued arms) is RX-side; this
  change does not touch RX arming. Do not enable during a bring-up arm; bring-up already
  starts the daemons after the arm.
