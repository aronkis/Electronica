# ops/ — operator kit

Scripts that touch the rig. Each one is either named by a docs page, invoked at
runtime by a script that is, or a profile/fixture such a script loads; nothing
here is a campaign one-off. `comb/` keeps only the four files the kit still uses
(the shared frames/slot plumbing `accept_analyze.py` is pinned to, the comb-period
scorer, the package marker, and the band sweep `docs/bringup.rst` names); the rest of
the comb campaign, and all of `rxfix/`, `agents/`, `seqbist/` and the per-run drivers,
are retired -- recoverable from tag `archive/pre-cleanup-2026-09-09`, with their
conclusions in `docs/evidence/`.

ADRV9002 profiles the boards load are in `profiles/` (`provision.sh` scps the
`.bin`+`.json` pair to `/root/`). `skidfix/` is the netlist fix-injection and
flash-rail kit, staged here until cleanup sub-project 2 moves it under `modem/`.

Board-side paths (`/root/host_app_k5/`, `/root/lvds_*.{bin,json}`) are NOT
repo paths and are deliberately unchanged by the rename — the boards in the rig
already carry them, and `link_test.sh preflight` checks for them.

| Script | Purpose | Doc |
|---|---|---|
| `anyssh.sh`, `askpass.sh` | Password-ssh transport every board call goes through | setup-prebuilt |
| `deploy_kernel.sh`, `deploy_dtb.sh`, `deploy_image.sh` | Flash kernel, dtb, BOOT.BIN from `images/` (size-checked, backed up) | setup-prebuilt |
| `provision.sh <ip>` | Host app sources (built on-board), `profiles/`, watchdog onto one board | setup-prebuilt |
| `lock_watchdog.sh` | On-board acquisition watchdog (deployed to `/root/` by `provision.sh`) | setup-prebuilt |
| `restore_known_good.sh` | Full both-board restore to the banked image + rung | setup-prebuilt |
| `bringup_r2r3.sh r2\|r3` | Profile, LO plan, ROM double-tap, daemons, watchdogs on both boards | bringup |
| `apply_146_ssi_fix.sh <ip> <clk> <dat>` | SSI delay override via the SAFE cache protocol (called by `bringup_r2r3.sh`) | bringup |
| `health_probe_reset_aware.sh <ip> <n>` | Two-pass health gate; healthy = fsync 1245 | bringup |
| `exp_forward.sh` | Verified-lock forward loop (watchdog → probe → score) | bringup |
| `comb/__init__.py` | Package marker so `from comb.common import ...` resolves in the kit's tests | testing |
| `comb/band_ber_sweep.sh` | RF band sweep used when a leg is antenna-limited | bringup |
| `sim_repro/riglock.sh`, `sim_repro/no_arm_inflight.sh` | Rig mutex and arm-in-flight guard | bringup |
| `sim_repro/delivery_sentinel.sh`, `sim_repro/sentinel_keeper.sh` | Delivery recovery loop and the unit that keeps it alive | bringup |
| `capture_r3.sh` | Credited PER window; writes `frames.bin` + `recovery.txt` | measurement-discipline |
| `accept_analyze.py` | Acceptance scoring; lost frames stay in the denominator | measurement-discipline |
| `recovery_windows.py` | The ONE reader of `recovery.txt` (what is excluded, and why) | measurement-discipline |
| `frame_taxonomy.py` | Assumption-free error-source derivation from `frames.bin` | measurement-discipline |
| `align_frames.py` | Errored frames → `pair.iq` windows | measurement-discipline |
| `check_capture_health.py` | Capture-path health gate: is this IQ the modem, or garbage? | measurement-discipline |
| `loss_ledger.py` | Class accounting behind `docs/evidence/LOSS_LEDGER.md` | measurement-discipline |
| `paired_report.py` | Run-level paired analysis for interleaved captures | measurement-discipline |
| `comb/comb_period_ms.py`, `comb/common.py` | Comb-period scorer and the shared frames/slot plumbing it and `accept_analyze.py` are pinned to | measurement-discipline |
| `arq_r3.sh` | R3/f1536 ARQ delivered-PER measurement, both directions | measurement-discipline |
| `launch_rig_unit.sh` | Run a rig script as a frozen copy under a systemd user unit | measurement-discipline |
| `test.sh loopback\|bist\|link` | Tier A/B/C entry point | testing |
| `link_test.sh` | Two-Jupiter RF link test (preflight, ber, tun) | testing |
| `link_test_1536.sh` | Same, for the retired f1536 rung; kept only for rollback against a frozen Image A board, not cited by any current doc page | testing |
| `ber_loopback_gate.sh <ip>` | On-board internal FPGA loopback BER gate | testing |
| `measure_ber.sh <ip> <nreads>` | On-chip hardware BIST BER | testing |
| `rf_loopback.sh <ip> [lo_mhz]` | Single-board RF loopback | testing |
| `mux_test.sh` | Daemon-restart mux/tap survival check | debug-instruments |
| `rate_probe.sh` | Per-stage rate probe | debug-instruments |
| `tap_smoke.sh` | Exercise the four IQ tap mux modes | debug-instruments |
| `capture_paired.sh A\|B` | Paired capture (Tap-A during a live scored window) | debug-instruments |
| `capture_evm.sh` | EVM capture off the tap | debug-instruments |
| `dcp_rail_dump.tcl` | Implemented-design rail/enable forensics (used by the `skidfix/` build rails) | debug-instruments |
| `profiles/lvds_*.{bin,json}` | ADRV9002 profiles: r3 `61p44_fdd` (deployed), r2 `30p72_fdd`, legacy `1p92_mhz`, f1536 `15p36` | bringup |
| `skidfix/` | Netlist fix injection + flash rails; staged for cleanup sub-project 2 | build-and-flash |
| `tests/` | Unit tests for the kit's scorers and the skidfix injectors | testing |
