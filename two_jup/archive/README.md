# two_jup/archive — superseded scripts (kept for history)

These are earlier bring-up / gate / diagnosis scripts, **superseded** by the current
kit (`link_test.sh`, `test.sh`, `provision.sh`, and the `-B` scorer gates). Kept for
reference; not part of the recurring build/test flow. Some hardcode transient paths
(e.g. sibling build logs that no longer exist).

| Script | What it was | Superseded by |
|---|---|---|
| `fdd_tun_wd.sh` | FDD tun bring-up, watchdog both (no stagger) | `link_test.sh tun` |
| `fdd_tun_staggered.sh` | FDD tun, manual stagger | `link_test.sh tun` |
| `fdd_coldstart_wd.sh` | FDD coldstart with echo daemons | `link_test.sh tun` |
| `fdd_clean_retry.sh` | FDD clean-retry loop | `link_test.sh` |
| `fdd_sep_test.sh` | LO-separation sweep | (diagnosis, one-off) |
| `fdd_gonogo.sh` | unarmed-modem golden go/no-go verdicts | `link_test.sh preflight` |
| `gonogo.sh` | reboot-until-good (its arm recipe was copied into `byte_link_up.sh`) | `link_test.sh` |
| `preflight.sh` | old reachability + identity + DDS-tone preflight | `link_test.sh preflight` |
| `g1_final_chain.sh` | wait-for-build → G1 gate wrapper (dangling build log) | `build_image.sh` + gates |
| `g1_pn_chain.sh` | wait-for-build → G1 PN gate wrapper | `build_image.sh` + gates |
| `g1_stock_chain.sh` | wait-for-build → G1 stock gate wrapper | `build_image.sh` + gates |
| `g2_resolver_chain.sh` | wait-for-build → G2 resolver gate wrapper | `build_image.sh` + gates |
| `g1_gate.sh` | G1 BIST-on-air image gate | `test.sh bist` / `ber_loopback_gate.sh` |
| `g1_pn.sh` | G1 PN-payload gate | `test.sh ber` |
| `g3_ota_byte.sh` | G3 OTA byte gate | `test.sh ber` / `link_test.sh ber` |
| `byte_echo_g2.sh` | G2 byte internal-loopback echo gate | `ber_loopback_gate.sh` |
| `arm_ch1.sh` | single-board FDD arm helper (ch1) | inlined into `link_test.sh` |
| `arm_jup.sh` | single-board FDD arm helper | inlined into `link_test.sh` |

## 2026-07-20 cleanup batch (campaign scratch → archive)

The root-cause campaign left ~80 one-off capture/analysis/experiment scripts and
several superseded analysis notes at the `two_jup/` top level. They are archived
here — none is called by the current tooling (`link_test.sh`, `test.sh`,
`provision.sh`, `deploy_image.sh`, `tap_smoke.sh`, and the `-B` gates). Grouped:

- **Captures & replay:** `capture_esrc/floor/gold/rom/rx.sh` (the live capture path is `capture_paired.sh`, kept).
- **Error hunts / census / episodes:** `error_hunt{,_ch2}.sh`, `seq_census{,_ch2}.sh`, `episode_stats.py`, `t87_protocol.sh`, `gonogo_verdict.py`.
- **Constellation / EVM / cyclostationary analysis:** `blind_evm{,2,16}.{m,py}`, `cyclo{,2,3,3f}.m`, `determine_source.m`, `sound_channel.m`, `sym_analysis.m`, `along_frame.m`, `phase_psd.m`, `phase_traj.m`, `loanalyze.m`, `loopbw_sweep.m`, `cfo_research.m`.
- **Impairment reproduction / decode experiments:** `reproduce.m`, `src_and_fix.m`, `resample_sweep.m`, `test_{canc,eq,iq,phasetrack}.m`, `dqpsk_fix.m`, `real_dqpsk.m`, `evenodd.m`, `swapcheck.m`, `capmatch.m`, `ne_diff.m`, `payload_diff{,2}.m`, `offdecode{,2}.py`.
- **Golden-vector gen / correlation:** `gen_golden{,2}.m`, `xcorr_gold.m`.
- **Tone / DDS / LO diagnostics:** `dds_tone.sh`, `tone_{path,tick}.sh`, `tone_verify.m`, `tone_check.py`.
- **RF asymmetry / freq / interferer experiments:** `freq_swap.sh`, `sweep_146rx.sh`, `gain_pin_test.sh`, `test_gainboost.sh`, `test_quietband.sh`, `tx_interferer_verify.sh`, `trim_cfo.sh`, `characterize_residual.sh`, `trackB_ch2_rx_test.sh`.
- **Near-end / RF-loopback experiments:** `near_end_loopback.sh`, `nel_{p1dtap,rawcap}.sh`.
- **Soak / rearm:** `soak_harness.sh`, `rearm_soak.sh`.
- **Superseded link/acceptance variants** (→ `link_test.sh` / `test.sh`): `accept_final{,_ch2}.sh`, `byte_link_up.sh`, `link_test_1536.sh` (15.36 MHz probe), `fdd_tun_quiet.sh`, `tun_ssh_key.sh`, `ber_ota.sh`, `live_check.sh`.
- **Channel-2 A/B** (ch1 adopted): `ch2ify.sh`, `tap_smoke_ch2.sh` (+ the `*_ch2` hunts above).
- **Superseded analysis notes** (→ `ERROR_TAXONOMY.md` / `ESCALATION_ADI.md`): `ERROR_SOURCE_ANALYSIS.md`, `OTA_ERROR_ANALYSIS.md`, `RTL_REPLAY_FINDINGS.md`, `STATE_CAPTURE_PLAN.md`, `P1B_TAP_MAP.md`, `RESULTS_channels.md`.

Data-output dirs (`tapsmoke/`, `esrc*/`, `floorcap/`, `gonogo_logs/`, `livechk/`, `resid/`, `soak/`) were untracked (now gitignored) — captures/logs, not source.
