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
