# TESTING — MATLAB is the primary test runner

`tests/runTests.m` is the single entry point. It discovers every
`matlab.unittest` `TestCase` under `tests/`, selects by level tag, emits
JUnit-XML + TAP into `tests/results/`, and exits nonzero on failure under
`matlab -batch`. See `tests/README.md` for the full guide.

```bash
matlab -batch "cd tests; runTests"            # L1 host-pure (< 3 min)
matlab -batch "cd tests; runTests('L2')"       # HDL gate stamps (RUN_GATES=1 executes)
QPSK_HIL=1 matlab -batch "cd tests; runTests('L3')"   # RF link, needs both boards
sudo -E matlab -batch "cd tests; runTests"     # also exercises the root-gated tun/tap tests
```

| Level | Scope | Needs |
|---|---|---|
| **L1** | C tests (`make test`), MATLAB↔C frame contract, byte/decode selftests, tun/tap loopback | nothing (tun/tap need root → Incomplete otherwise) |
| **L2** | HDL gate verdicts (stamp check; `RUN_GATES=1` runs the ~30 min suite) | MATLAB (+Vivado for exec) |
| **L3** | tun bring-up, latency, iperf/UDP, TCP, SSH usability | `QPSK_HIL=1` + boards 10.0.0.148/146 |

The hardware acceptance ladder below is the operator procedure the L3 tests
automate (driven through `two_jup/link_test.sh`):

```bash
cd two_jup
./test.sh loopback          # Tier A: self-loopback (host + internal FPGA), no RF
./test.sh bist              # Tier B: on-chip BIST comparator (golden cap_out)
./test.sh ber               # Tier B: host full-packet scorer (buckets + BER)
./test.sh link --radios 2   # Tier C: real data, two-board FDD quiet pair
./test.sh link --radios 1   # Tier C: real data, single-board RF loopback (needs cable)
./test.sh all               # ladder: host tests -> preflight -> ber
```

## The acceptance ladder (run top to bottom)

| Rung | Command | Proves | Healthy result |
|---|---|---|---|
| 1. Host contract | `test.sh loopback` (host part) | frame/FEC/scorer/whitener logic is correct off-hardware | `388/35` tests 0-failed; `qpsk_ber_selftest OK` |
| 2. Digital loopback | `test.sh loopback` (board part) | the FPGA datapath decodes its own Tx with `rx_input_select=0` (no RF) | echo CRC-pass **and** `-B` BER ≈ 0 |
| 3. On-chip BIST | `test.sh bist` | the in-fabric "ADI Hello World" comparator locks | `cap_out(0x144) = 0x04922282`, counter BER low |
| 4. Real BER | `test.sh ber` / `link --radios 2` | real RF link carries data both directions | CLEAN ≥ ~95%, BER ~1e-4, `rstcs` delta ~0 |
| 5. IP / SSH | `link_test.sh tun` / `ssh` | IP-over-RF and an encrypted session survive | `tun0` up both ways; `RF-SSH-OK` |

A failure at rung N localizes the problem below rung N+1 (e.g. rung 2 fails but rung 1
passes → FPGA/image, not the host logic).

---

## Tier A — self-loopback (NO RF)

Everything here runs without over-the-air RF; the datapath is looped back digitally.

- **Host unit tests** (dev box, `make -C host_app_k5 test`): `test_frame` (frame
  encode/decode, every single-bit corruption caught), `test_k5` (K5 FEC path),
  `test_ber` = `qpsk_ber_selftest` (the 5 buckets + whitener; identical to on-board
  `qpsk_tun -T`), `test_whiten` (whitener self-inverse/transparency). All must be 0-failed.
- **On-board internal FPGA loopback** (`ber_loopback_gate.sh <ip>`): arms ONE board with
  `rx_input_select=0` (0x114=0) so the receiver decodes the board's own transmit **with no
  RF**, then runs `qpsk_tun -T`, `-e` echo, and `-B`. Decision: echo CRC-pass **and** `-B`
  BER ≈ 0 ⇒ the FPGA datapath is sound (OTA is unblocked); echo passes but `-B` errors ⇒
  tool bug; both fail ⇒ arm/image problem. This is the calibration gate before any RF test.
- **RTL self-tests** (offline, `jupiter_240k5_byte/rtl_sim/`): the Verilator IQ-replay
  harness `sim_byte_iq` (`Vwrap_byte`) replays a captured `.iq` through the deployed byte
  RTL; the iverilog `tb_tx_240k5.v` dumps the Tx air stream. These are also the build-time
  S1B/S1 netlist gates (see [BUILD.md](BUILD.md)).

## Tier B — BER with BIST

Two **distinct** BER mechanisms — both belong here; keep them straight:

**(a) On-chip hardware BIST** — `test.sh bist` → `measure_ber.sh <ip> <nreads>`. The FPGA
has an internal "ADI Hello World" pattern generator + comparator whose counters live in the
modem regfile at base `0x9D000000`: `packets_out 0x104`, `bit_errors 0x108`, `cap_out 0x144`.
- **Golden readback:** `cap_out(0x144) == 0x04922282`. A mismatch means a wrong/broken image.
- **BIST BER:** `measure_ber.sh` sums positive counter deltas as `100*errors/(packets*120)`
  (120 BIST bits/packet) and reports `golden_frac` (fraction of reads at golden cap).
- Most meaningful **while a link or internal loopback is armed** (the comparator needs the
  internal pattern flowing); on an idle board it reads the last-locked golden cap.

**(b) Host full-packet scorer** — `test.sh ber` → `link_test.sh ber` → `qpsk_ber.c` via
`qpsk_tun -B`. Each board radiates a fixed 128-byte reference (`len==0` frame, PN9-padded)
and scores **every** received packet (including CRC failures — they carry the errors) over
1024 bits into buckets:

| Bucket | Meaning | Counts toward BER? |
|---|---|---|
| CLEAN | aligned, 0 bit errors | yes |
| NOISY | aligned, < 10% bit errors | yes (the errors) |
| ROTATED | a word-rotation aligns it (framing/word slip) | no |
| PHASE | aligned but ≥ 35% wrong (phase-ambiguity / 180° slip) | no |
| MISS | none of the above (false trigger on noise) | no |

Only **CLEAN + NOISY** feed BER. A healthy quiet-pair link: **CLEAN ≥ ~95%, BER ~1e-4,
`rstcs`(0x150) delta ~0** over the run. A large `rstcs` delta = CFO reset storm = wrong
image (the rxfix keeps it ~0).

## Tier C — real data over a real link (one or two radios)

- **Two radios** (`test.sh link --radios 2`, or `link_test.sh {ber,tun,ssh}`): the FDD quiet
  pair — FORWARD 146→148 @ 2.00 GHz, REVERSE 148→146 @ 1.90 GHz (dodges 148's 2.10 GHz Tx-LO
  leakage). `ber` is the read-only-safe quality metric; `tun` brings up `tun0` both ways;
  `ssh` runs an encrypted session over `tun0` (judged by the `RF-SSH-OK` token). Judge quality
  by `ber`/`ssh`, **not** by ping (ping payloads are low-entropy and lossy even on a good link).
- **One radio** (`test.sh link --radios 1` → `rf_loopback.sh <ip> [lo_mhz]`): single-board RF
  loopback exercising the real DAC→PA→**[external Tx→Rx cable + ~30-40 dB attenuator]**→LNA→ADC
  chain, Tx LO == Rx LO. This is distinct from Tier A's *digital* loopback. Ready-to-run once
  the cable is rigged; not hardware-validated in this kit (no loopback cable was present).

---

## On-board prerequisites & provisioning

`link_test.sh preflight` verifies each board has: `/root/host_app_k5/qpsk_tun` (executable),
`/root/lvds_1p92_mhz.{bin,json}`, `/root/lock_watchdog.sh`, and working modem reg access.
Install them with `provision.sh <ip>` (after `deploy_image.sh` flashes the image) — see
[BUILD.md](BUILD.md) §Deploy. Board scratch/logs go to `/dev/shm` (`ber.log`, `qpsk_tun.log`,
`watchdog.log`), never `/tmp`.

## Safety (Tier B/C touch fragile hardware)

Jupiter has **no remote power** — a wedge = physical reflash+reboot. The test scripts honor:
never flash `BOOT.BIN`; no Rx S2MM capture > 512 KB (wedges the board); one `anyssh` per board
arm; the two boards arm in parallel (never two concurrent sessions to the *same* board — the
`A_IP==B_IP` guard enforces this); board scratch → `/dev/shm`. On any board cycle, quiesce and
stop.
