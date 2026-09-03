# Two-Jupiter FDD Link — Where We Sit (2026-07-10)

**Goal:** bidirectional FDD RF link between two Jupiter SDRs (A=10.0.0.148, B=10.0.0.146),
240 ksym QPSK + K=5 FEC, carrying IP over tun0 well enough for **SSH / iperf**.

## DONE & validated on live silicon
- **Root cause of the BER floor found & fixed.** The intermittent floor was a Rx
  **CFO-step-change-detector reset storm**: `CFOChangeDetectThreshold` at the stock
  0.0015625 (~697 Hz deadband) false-fired the carrier-loop reset ~52/s while the true
  CFO was a stable ~26 Hz. **Fix = 0.0125 (~5577 Hz)** in the model + all 4 build gates.
  Built (BOOT.BIN md5 `8d6b82ff597e`) and **deployed to both boards** (backups
  `/boot/BOOT.BIN.prerxfix`, reflash-recoverable). **Live acceptance: rstcs 52/s→0,
  frame yield 40%→93.5%, golden cap_out recovered.**
- **Residual characterized.** 146 Rx was weak *only at 2.10 GHz* = **148's own Tx-LO
  leakage** (park 148 LO at 1.5 GHz → 146 noise 515→11; wideband sweep clean elsewhere).
  Moving to the **quiet pair 2.00/1.90 GHz** → `-B` BER **~1e-4 both directions**
  (from the old 2–3e-3 floor).
- **Forensics deliverables:** `ERROR_SOURCE_ANALYSIS.md`, `RTL_REPLAY_FINDINGS.md`;
  ideal-receiver `k5_240/decode_ref_k5.m` (decodes floor captures to BER=0 → impairment
  is in the samples, not the decode); regenerated `k5_240/awgn_k5.m` SNR anchor.

## IN PROGRESS — SSH over tun0
- **Key insight (code-confirmed):** the `-F` daemon delivers real IP traffic at
  `dma_rx_ok=0` while the modem is LOCKED because low-entropy IP payloads (ping's
  sequential ramp, TCP/IP headers) get RF-corrupted. Keepalive frames lock fine because
  their padding is PN9-filled (high entropy). **SSH's post-KEX stream is encrypted =
  high-entropy = self-whitening**, so it should pass where ping fails.
- `two_jup/tun_ssh_key.sh`: sets up ed25519 **pubkey auth out-of-band** (installed on 148,
  `PermitRootLogin yes`), brings up the quiet-pair link `WHITEN=0` (both boards lock),
  runs an **entropy discriminator** (urandom over tun0 → does `dma_rx_ok` climb?), then
  SSHes 146→148 over tun0 with minimal-KEX (ed25519 hostkey, curve25519, chacha20) +
  robust timeouts. **[result pending — run in flight]**

## "Did the whitener break lock?" — almost certainly NO (misdiagnosis)
`LOCKED` = FPGA `0x104` packets_out advancing (PHY-layer, byte-content-agnostic). The host
whitener only XORs payload byte *values* → cannot stop `packets_out`. Real whitener failure
mode = **one-end-only interop mismatch** (`qpsk_frame.c:63` warns both ends must whiten) →
zero delivered frames → looks like "no link" if watching pings. **To confirm:** a `WHITEN=1`
run (both daemons) and read the watchdog `LOCKED` line + `dma_rx_ok` directly.

## Remaining blockers to reliable SSH
1. **Low-entropy payload loss** — fixable with the whitener *if* it's set on BOTH ends
   (pending the WHITEN=1 confirmation above), or ride on SSH's own encryption entropy.
2. **~20% EVM LO phase-noise margin** — thin link budget even at 1e-4 BER
   (closer antenna spacing / better LO ref / 148 Tx-LO-leakage cal).

## Next steps (in order)
1. Read the in-flight `WHITEN=0` SSH result (`resid/tun_ssh_key.log`).
2. `WHITEN=1` run to settle the whitener-vs-lock question and, if it passes data, retry SSH.
3. If SSH holds, `iperf` soak; else attack the RF margin.

## Key paths
- Fix: `jupiter_240k5_byte/commhdlQPSKTxRxParameters.m:45` (=0.0125)
- Link/SSH tooling: `two_jup/{tun_ssh_key,fdd_tun_quiet,test_quietband,sweep_146rx}.sh`,
  `two_jup/anyssh.sh`, `two_jup/lock_watchdog.sh`
- Daemon/frame: `host_app_k5/qpsk_tun.c`, `qpsk_frame.c` (CRC + whitener + PN9 keepalive)
