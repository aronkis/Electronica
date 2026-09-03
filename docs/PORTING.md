# PORTING — bring the link up on a DIFFERENT pair of Jupiters

This is the thin delta for standing the two-Jupiter QPSK-K5 link up on a **fresh
pair of ADALM-Jupiter (ADRV9002) boards** — different management IPs, different
antennas, a different RF environment. It reuses the existing operator procedure
[BRINGUP.md](BRINGUP.md) verbatim; only the parts that are tied to *our*
specific boards (A=10.0.0.148 / B=10.0.0.146) change, and those are all
overridable. Read this once, then follow BRINGUP.

> **Everything in the repo is board-agnostic already.** `anyssh.sh`,
> `provision.sh`, the LVDS profiles, `lock_watchdog.sh`, the host app sources,
> and `link_test.sh`'s arm sequence carry **no** hardcoded IP or board identity
> (the arm uses the fixed channel-1 datapath: `voltage0`, `TX1/RX1` LO,
> `tx_a`, `agpio4-7` — same on any board). The only board-specific inputs are
> the four env knobs in Step 3 and the RF tuning in "What you MUST re-survey".

## What a fresh pair needs (all in this repo except the image)

| Piece | Source | Board-agnostic? |
|---|---|---|
| Board access wrapper | `two_jup/anyssh.sh` + `askpass.sh` (password `analog`) | yes — IP is an arg |
| Flash tool | `two_jup/deploy_image.sh <ip> [BOOT.BIN]` | yes |
| On-board files | `two_jup/provision.sh <ip>` (host app + LVDS profile + watchdog) | yes |
| Operator entry point | `two_jup/link_test.sh` (`preflight`/`ber`/`tun`/`ssh`/`perf`/`lat`) | yes — IPs/freqs are env |
| Host app sources | `host_app_k5/*.c` (built on-board by `provision.sh`) | yes |
| **BOOT.BIN image** | **NOT in the repo** — see Step 0 | image, not board-specific |

### Why the image is not committed
`BOOT.BIN` is a ~7 MB build artifact. The repo excludes it by design (see the
root `.gitignore`), and — critically — **its md5 is not reproducible across
Vivado rebuilds**, so a committed hash would be misleading. Image *identity is
by function*, not md5: a correct image passes the build gates and reads back the
on-chip BIST golden `cap_out = 0x04922282` (see [PROVENANCE.md](PROVENANCE.md)).
Get the image out-of-band (Step 0).

## Step 0 — obtain the modem image

Two routes; either yields a functionally-equivalent image (verify by size
`7203552` + BIST golden, not md5):

- **Copy the prebuilt artifact** (fastest). The current shipped image is the
  **lean build** — `two_jup/deploy_image.sh` defaults to it:
  `jupiter_byte_lean_build/hdl_prj_jupiter_composite/vivado_ip_prj/boot/BOOT.BIN`.
  If you clone the repo onto a different machine, that build tree is gitignored —
  `scp` the `BOOT.BIN` file across alongside the clone and point `deploy_image.sh`
  at it: `./deploy_image.sh <ip> /path/to/BOOT.BIN`.
- **Build from source** (~2 h, needs MATLAB + HDL Coder + Vivado): follow
  [BUILD.md](BUILD.md) (`jupiter_240k5_byte/build_image.sh`). The result passes
  the same gates and BIST golden.

## Step 1 — verify reachability

```sh
cd two_jup
./anyssh.sh <A_ip> 'echo up'   # expect: up   (password auth, no keys needed)
./anyssh.sh <B_ip> 'echo up'
```
If your boards use non-default mgmt IPs, that's fine — every tool takes the IP
as an argument or env var.

## Step 2 — flash both boards (staged, one at a time)

```sh
./deploy_image.sh <A_ip>        # backs up current /boot -> .pregeneric, flashes, reboots, waits
./deploy_image.sh <B_ip>        # only after A is confirmed back up
```
`deploy_image.sh` keeps a rollback copy at `/boot/BOOT.BIN.pregeneric`
(`cp` it back + `sync` + `reboot` to revert). It refuses to touch `/boot` unless
the new image is >6 MB and staged-verified first. **Flash one board, confirm it,
then the other** — the backup is overwritten each run, so serial flashing keeps a
known-good rollback on the peer.

## Step 3 — provision + point the tools at YOUR boards

```sh
./provision.sh <A_ip> && ./provision.sh <B_ip>     # builds qpsk_tun, stages profile + watchdog

# tell link_test.sh which boards are A and B (and, later, your frequencies):
export A_IP=<A_ip> B_IP=<B_ip>
./link_test.sh preflight                            # expect: PREFLIGHT: PASS (both boards ready)
```
(`A_IP`/`B_IP` can also be passed per-call as `-A`/`-B`.) "Board A" vs "Board B"
is just a role label — assign it however you like; the frequency plan is keyed to
the roles.

## Step 4 — arm, acquire, measure

From here, **follow [BRINGUP.md](BRINGUP.md) §2–§5 exactly** — arm sequence,
verified-lock acquisition loop, Rx-gain pin, and the acceptance ladder are all
board-agnostic and driven by `link_test.sh`:

```sh
./link_test.sh ber -d 90        # OTA BER both directions
./link_test.sh tun              # IP-over-RF (ping both ways)
./link_test.sh ssh              # SSH over the RF link
QPSK_HIL=1 matlab -batch "cd ../tests; runTests('L3')"   # full HIL suite w/ your A_IP/B_IP
```

---

## What you MUST re-survey for your pair (do NOT copy our numbers)

Everything below in BRINGUP is **specific to boards A/B and their bench** — a
different pair, in a different environment, will differ (possibly better). Treat
our values as *starting points*, not expected results:

- **Frequency plan** (BRINGUP §2: forward 2.00 GHz / reverse 1.90 GHz "quiet
  pair"). This came from a 1.5–2.1 GHz RF survey of *our* boards; 2.10 GHz was
  polluted by 148's Tx-LO leakage — an artifact of that specific unit. **Re-run
  the survey for your pair** and set `FWD_HZ`/`REV_HZ` (or `-f`/`-r` in MHz)
  accordingly. Start with the defaults, then sweep carriers with
  `./link_test.sh ber -f <MHz> -r <MHz> -d 60` and pick the cleanest quiet pair.
- **Rx-gain pin value** (BRINGUP §4). The captured gain is the settled operating
  point *of our link budget* — re-capture it on your boards after their own
  verified lock. The *procedure* is universal; the number is not.
- **BER expectations** (BRINGUP §5: reverse ~2e-6, forward ~1.4e-4). The forward
  floor is *our* 148 Rx1 physical-path limit, not a property of the design. Your
  numbers depend on your antennas, cabling, and RF path. Don't chase our 1.4e-4.
- **The ~1.5 s "tick"** (forward MISS ~0.4%). This is a **per-unit BBDC
  calibration artifact observed on ONE of our boards (148)** — chip-level,
  OTA-only, absent on 146. See `two_jup/ESCALATION_ADI.md`. The shipped lean
  image carries the P1E-v3 tick *compensation* (an acc-position-qualified deint
  skip); on a board that does **not** exhibit the tick it is a **no-op** and
  costs nothing. Check whether your boards tick before assuming you need it —
  a clean `./link_test.sh ber -d 300` with MISS ≈ 0 means you don't.

If your pair locks and shows a clean `cap_out=0x04922282` BIST, healthy `ber`,
and `rstcs` ≈ 0, the link is up — the tuning above is optimization, not
bring-up.
