# Two-Jupiter QPSK RF Link Test — Operator Guide

`link_test.sh` is a single operator entry point for bringing up and measuring the
two-board QPSK RF link **using the boot files already flashed on the boards**. It
never flashes, never reboots, and never does anything that can wedge a board.

```
./link_test.sh <subcommand> [options]
```

---

## 1. What this is / Prerequisites

Two ADALM-Jupiter boards are connected over the air in an FDD (frequency-division
duplex) QPSK link. This kit lets you verify that link and measure its quality from a
host on the wired management LAN.

Before you run anything, all of the following must already be true:

- **Both boards are flashed with the current image** (lean `dcf5c5fb`; carries the
  `rxfix` CFO-step-detector fix, `CFOChangeDetectThreshold = 0.0125`). This kit does
  **not** flash — it assumes the boot files are already on the boards. See
  [../docs/PROVENANCE.md](../docs/PROVENANCE.md).
- **Wired management LAN reachable** to both boards. Board A = `10.0.0.148`,
  Board B = `10.0.0.146`.
- **`anyssh.sh` works** (password auth over the wired LAN, already set up). Every board
  command in `link_test.sh` goes through `anyssh.sh <ip> '<remote cmd>'`. `link_test.sh`
  resolves `anyssh.sh` next to itself, so keep the two files in the same directory.
- **These four files exist on each board** (put there at flash time):
  - `/root/host_app_k5/qpsk_tun` — the modem host app (executable)
  - `/root/lock_watchdog.sh` — on-board acquisition watchdog
  - `/root/lvds_1p92_mhz.bin` — LVDS 1.92 MHz stream profile
  - `/root/lvds_1p92_mhz.json` — LVDS 1.92 MHz profile config

`preflight` verifies every one of these for you; run it first.

### The link geometry (read this before anything else)

The link runs on the **quiet pair** — forward at 2.00 GHz, reverse at 1.90 GHz — chosen
to avoid Board A's (148) 2.10 GHz Tx-LO leakage that jams 146's receiver. "Forward"
runs **B → A** (146 → 148), which is easy to misread because A has the *lower* label but
the *higher* IP. Keep this table handy:

| Board | IP | Transmits | Receives | In `ber`, this board scores |
|-------|-----------|--------------------|--------------------|-----------------------------|
| **A** | `10.0.0.148` | 1.90 GHz (reverse) | 2.00 GHz (forward) | **forward** link 146 → 148 |
| **B** | `10.0.0.146` | 2.00 GHz (forward) | 1.90 GHz (reverse) | **reverse** link 148 → 146 |

In the BER test each board radiates its own reference and scores what **it** receives, so
you get **two** independent reports — one per direction. When reading them: **148's report
is the forward link, 146's report is the reverse link.**

---

## 2. Quick start

```
# 1. Verify both boards are ready (safe — no arm, no RF)
./link_test.sh preflight

# 2. Run the main link-quality test: ~60 s BER measurement, both directions
./link_test.sh ber
```

`preflight` must PASS on both boards before `ber` is meaningful. `ber` is read-only-safe
(it needs no Rx capture) and is the reliable quality metric for the link.

---

## 3. Subcommands

Every subcommand acts on both boards via `anyssh.sh`. The two boards are armed **in
parallel**, but each board's arm is a single ssh call (never two concurrent sessions to
the same board — see Safety).

### `preflight` — readiness check (safe, no arm)
```
./link_test.sh preflight
```
For **both** boards, with no arming and no RF, verifies: board reachable;
`/root/host_app_k5/qpsk_tun` executable; `/root/lvds_1p92_mhz.{bin,json}` present;
`/root/lock_watchdog.sh` present; modem register access works. Prints `cap_out` (`0x144`),
`rstcs` (`0x150`), and `level`. Prints a clear **PASS/FAIL per board** and exits nonzero
if either board FAILs. Run this first, every session.

### `ber` — the main link test (read-only-safe, the reliable quality metric)
```
./link_test.sh ber            # default 60 s
./link_test.sh ber -d 90      # longer run; less lock-transient in the BER
```
Quiesces both boards, arms both on the quiet pair (the byte DMA is armed as the last step of
each board's single arm call), launches the on-board watchdog on each, then runs the `-B` BER
mode on **both** boards at once for `DUR`
seconds. Each board radiates a fixed 128-byte reference and scores the frames it receives
(~211.8 frames/s). At the end it prints, **per direction**, the final `frames_scored`, the
bucket percentages, and `BER`, plus the `rstcs` delta over the run, then quiesces. This
test does **no** Rx capture, so it cannot wedge a board. See §4 for how to read it.

### `tun` — bring up an IP tunnel over the RF link (leaves the link up)
```
./link_test.sh tun            # whitener OFF (default)
./link_test.sh tun -w         # whitener ON (both ends)
./link_test.sh tun -k         # tear the link down when done
```
Quiesces, arms both, launches watchdogs, launches `qpsk_tun -F -i tun0`
(`QPSK_WHITEN` set from `-w`), configures `tun0` (addr/peer `10.66.0.1 ↔ 10.66.0.2`,
mtu 116, route), waits for lock, then **pings both directions** (10 packets each, `-W 3`)
and reports. The link is **left up** afterward (use `-k` to tear it down).

> **Ping shows loss even on a healthy link.** ICMP echo uses a low-entropy payload that
> stresses the modem's carrier/timing loops, so ping loss is *expected* here and is **not**
> a verdict on link health. Judge the link by `ber` or `ssh`, not ping. (The host whitener
> mitigates low-entropy payloads, but it must be set identically on **both** ends or every
> frame fails CRC — `-w` sets it on both for you.)

### `ssh` — prove a real interactive session over the RF link (leaves the link up)
```
./link_test.sh ssh
./link_test.sh ssh -k         # tear down after
```
Everything `tun` does, plus: installs an ed25519 pubkey out-of-band (B is the client, A is
the server) over the wired LAN, then attempts `ssh B → A over tun0` using minimal-KEX /
robust options (ed25519 hostkey, curve25519 KEX, chacha20 cipher, long timeouts). Prints
the ssh transcript. A successful `RF-SSH-OK` transcript is the strongest proof the link
carries real, high-entropy traffic. Link **left up** unless `-k`.

### `status` — read modem registers on both boards (no arm)
```
./link_test.sh status
```
Reads and prints, for both boards without arming: `cap_out` (`0x144`), `rstcs` (`0x150`),
`cfc` (`0x154`), `level` (`0x15C`), `packets_out` (`0x104`), and `rssi`. Use it any time to
snapshot the link — e.g. while a `tun`/`ssh` session is left up — without disturbing it.

### `down` / `clean` — tear everything down
```
./link_test.sh down
./link_test.sh clean          # same thing
```
Quiesces both boards: kills `lock_watchdog` and `qpsk_tun`, flushes `tun0`. Run this to
leave the boards idle after a `tun`/`ssh` session.

### Options

| Flag | Meaning | Default |
|------|---------|---------|
| `-A <ip>` | Board A IP | `10.0.0.148` |
| `-B <ip>` | Board B IP | `10.0.0.146` |
| `-d <secs>` | `ber` run length (includes the lock transient — use `90` for a steady-state figure). **No effect** on the tun/ssh lock wait, which is a fixed ~40 s. | `60` |
| `-f <fwd_mhz>` | forward carrier in **MHz** | `2000` (2.00 GHz) |
| `-r <rev_mhz>` | reverse carrier in **MHz** | `1900` (1.90 GHz) |
| `-w` | host whitener **ON** (both ends) for `tun`/`ssh` | off |
| `-k` | tear the link down after `tun`/`ssh` | leave up |
| `-h` | print usage | — |

Example with overrides:
```
./link_test.sh ber -A 10.0.0.148 -B 10.0.0.146 -d 60 -f 2000 -r 1900
```

---

## 4. How to read the results

### The `-B` BER report (from `ber`)

You get **two** reports, one per board / per direction (§1: 148 = forward, 146 = reverse).
Each ends with a summary like:

```
frames_scored=<N>  aligned(clean+noisy)=<N>  total_bits=<N>  bit_errors=<N>  BER=<n.nnne-nn>
buckets: CLEAN=<n>(nn.n%) NOISY=<n>(nn.n%) PHASE=<n>(nn.n%) ROTATED=<n>(nn.n%) MISS=<n>(nn.n%)
```

(`pkt = 128 B / 1024 bits`, ~211.8 frames/s.) The five buckets classify each scored frame:

- **CLEAN** — received, aligned, zero bit errors (this is what you want).
- **NOISY** — aligned but some bit errors.
- **PHASE** — a phase slip during the frame.
- **ROTATED** — constellation rotated.
- **MISS** — frame not found / not received.

**Healthy quiet-pair link:**

| Metric | Healthy | Bad |
|--------|---------|-----|
| `CLEAN` bucket | **≥ ~95 %** | well below 95 %, high MISS/PHASE/ROTATED |
| `BER` | **~1e-4** | orders of magnitude higher |
| `rstcs` delta (0x150) | **~0** | high / growing |

> **The `-B` window starts at arm**, so a short run folds the initial lock-acquisition
> transient into the numbers (slightly more MISS/BER than steady state). For a clean
> steady-state figure, use `-d 90`.

A **high or growing `rstcs`** is the tell-tale of the carrier-loop **reset storm** — it
means the board is *not* running the `rxfix` image (wrong/old `BOOT.BIN`) or something is
re-firing the CFO-step detector. With the correct `rxfix` image `rstcs` stays at ~0 across
the whole run. Check both boards' `rstcs` delta on every `ber` run.

### `cap_out` sanity value

`cap_out` (`0x144`, shown by `preflight` and `status`) reads back the golden value
`0x04922282` on a healthy, correctly-imaged board. A different value points at a bad image or
a modem not in the expected state.

### `tun` (ping) results

Ping loss is **expected even on a good link** — ICMP is low-entropy and stresses the modem
loops (§3, `tun`). Do **not** judge link health by ping. Use the `ber` CLEAN%/BER or a
successful `ssh` transcript as the verdict.

### `ssh` results

A transcript containing `RF-SSH-OK` (plus the remote `hostname`/`uname`/`uptime`) means a
real encrypted, high-entropy session went end-to-end over the RF link — the strongest
possible pass. SSH is self-whitening (encrypted traffic is high-entropy), so it can succeed
even when ping shows loss.

---

## 5. Safety notes (the script honors these — so must you)

1. **No remote power.** A Jupiter cannot be power-cycled remotely; a wedge means a physical
   reflash + reboot at the bench. The script is written to never do anything that can wedge
   a board — don't work around it.
2. **Never flash.** This kit uses the *existing* boot files. Nothing here writes
   `/boot/BOOT.BIN` or any boot media. If you find yourself flashing, you're off-script.
3. **No large Rx capture.** An Rx S2MM DMA capture larger than **512 KB wedges the board.**
   `link_test.sh` does no such capture — the `-B` BER test needs none. Do not add one.
4. **One ssh session per board during arm.** The two *different* boards arm in parallel (as
   the proven scripts do), but each board's arm/profile-reload is a **single** `anyssh` call
   — never two concurrent sessions to the *same* board while it is arming. One profile reload
   per bring-up.
5. **Scratch goes to `/dev/shm`.** Any on-board scratch/log (e.g. the BER log) lives in
   `/dev/shm`, never `/tmp`.

---

## 6. Troubleshooting

| Symptom | Likely cause | What to do |
|---------|--------------|------------|
| **Board not reachable** (preflight can't connect) | wired LAN / cabling / board not booted; wrong IP | Confirm the board is powered and on the management LAN; check `-A`/`-B` IPs; verify `anyssh.sh <ip> 'echo ok'` works by itself. |
| **`preflight` FAILs** | a required on-board file missing or not executable; modem reg access not responding | Read which check failed in the per-board output. Missing `/root/...` file → the board wasn't provisioned at flash time (reflash/reprovision at the bench). Reg-access fail → board may need a reboot. Do **not** proceed to `ber` until preflight PASSes. |
| **Link never locks** (all MISS, no CLEAN, `packets_out` not advancing) | no signal / wrong carriers / antennas; peer not armed | Confirm **both** boards armed (run `ber`/`tun`, not just one board); check antennas/attenuators; confirm `-f 2000 -r 1900` matches the quiet pair; the watchdog needs a real signal present to re-arm out of the noise wedge. |
| **`rstcs` high / growing** | board **not** on the `rxfix` image (reset storm), or CFO detector re-firing | This is the classic wrong-image signature. Verify the board is flashed with the `rxfix` `BOOT.BIN` (`CFOChangeDetectThreshold = 0.0125`). Reflash at the bench if needed — the script will not (and must not) flash. |
| **`ssh` times out** | link too marginal for a sustained session, or key/setup issue | First check `ber`: if CLEAN is well below ~95 % / BER is high / `rstcs` is climbing, fix the link first. If `ber` is healthy but ssh still fails, re-run `ssh` (it reinstalls the key out-of-band); confirm `tun0` is up on both ends via `status`. Remember ping loss alone is **not** a link failure. |
| **Ping shows loss but link seems fine** | expected — low-entropy ICMP | Not a fault. Judge by `ber`/`ssh`. If you need tun traffic to behave, try `-w` (whitener on both ends). |
| **Boards left in an odd state after a session** | `tun`/`ssh` leaves the link up by design | Run `./link_test.sh down` (or `clean`) to kill watchdog + `qpsk_tun` and flush `tun0`. |
