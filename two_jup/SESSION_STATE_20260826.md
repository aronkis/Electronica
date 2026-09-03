# Session state — 2026-08-26 (save-point for compaction)

Everything below is committed and pushed through `ceb9983` on
`per-under-1pct-2026-07` (push works; the vault issue resolved ~04:1x).
Authoritative evidence: `SINGLES_CAMPAIGN.md` dated sections through
2026-08-26; open questions: `KNOWN_HOLES.md`.

## The headline (changed everything this session)

The forward "singles comb" is NOT a 146 TX/byte-plane fault. Chain of proof:
1. Internal loopback on 146: comb absent (0.2–0.3% steady).
2. 1-ft self-reception on BOTH boards (full egress: byte plane→SSI→DAC→RF→
   antenna→OTA): 0.25–0.3% steady — TX exonerated end-to-end.
3. Comb requires CROSS-BOARD clocks (real XO offset ≈2.6 ppm SRO) and is
   violently CFO-SIGN-ASYMMETRIC on hardware: +15k true CFO → 6.0% steady,
   −15k → 85%, null → 12%, stock −5.15k → 13.0%.
4. RTL sim REPRODUCED it (commit 349c5c9, Jul-25 tap netlist): −15k+SRO 13.0%
   corrupt / +15k clean / CFO-only clean both signs (defect REQUIRES SRO).
   First divergent signal: Symbol_Synchronizer output → Peak_Search false
   latch +32 sym → Phase_Ambiguity mis-resolve. NAMED SUSPECT (not yet
   convicted): one-sided mu clamp, `Interpolation_Control.v:163-172` (mu
   saturates instead of wrapping; only negative-SRO slip exercises it).
   Artifacts: `two_jup/rtl_cfo_repro/`.
5. Whitening refuted (6.0% unchanged). Placement-sensitivity (A4/v_endh)
   likely receiver-side response to TX timing detail and/or single-window
   burst contamination (single 60s windows inflate up to ~+7pp — use
   multi-window min/median ALWAYS).

## Standing mitigations / config

- Forward RX LO default is now **+20k off-null** (`bringup_r2r3.sh`
  `LO_A_RX=${LO_A_RX:-2000020000}`, operator-acked): forward 13%→~6% steady.
- Rig VERIFIED at save time: 146 = **v_endh `ec414d2df8bc`** (the 12:58
  flash stands; no rollback ran after), 148 = BEATFIX
  `fe5bd8a4fe19` with fixctl=3 armed; both directions full rate; patched
  sentinel ACTIVE on nemo (now snapshots watchdog logs pre-recovery to
  `~/modem-status/wdlog_<ip>_<ts>.txt` — 4+ wedge snapshots already banked,
  H-6 evidence unexamined).
- v_endh `ec414d2df8bc` verdict: MOVED both legs opposite directions
  (idle 13.02% worse / saturated 11.46% better); slack correlate REFUTED.
  v_endh flash attempt 1 was VOID (148 died mid-gate; operator power
  cycle); attempt 2 SUCCEEDED (12:58) and **v_endh is the verified live
  image on 146 at save time** (probed 17:1x: ec414d2df8bc).

## Deliverables landed this session

- `boot_known_good/`: five BOOT.BIN images + MD5SUMS + README, actually in
  the repo (two gitignore traps + ALLOW_BIG precommit override — see
  ceb9983 and prior two commits for the saga).
- GitHub Pages live: https://tfcollins.github.io/qpsk-jupiter-modem/
  (workflow `.github/workflows/docs.yml`, sphinx -W pinned toolchain,
  deploys from master + campaign branch; github-pages environment has
  branch policies for both). Boot images downloadable from the site root
  (html_extra_path); site is PUBLIC while repo is private — operator aware.
- Docs: new `setup-prebuilt.rst` (no-toolchain deploy path), 2026-08-26
  update banner on `current-state.rst`, campaign plans/specs excluded from
  sphinx, AI/tooling references scrubbed, zero-warning build.
- `KNOWN_HOLES.md`: H-1..H-11 inventory; H-1 largely closed (repro + suspect).
- P2 audit: "fixed beats float 1.7-2dB" anomaly EXPLAINED (sps-4/sps-8
  ladder asymmetry); "ss first divergent stage" RETRACTED (cs is largest
  clean cost); float-zero reproduced on 08-24 capture but rests on ONE
  capture (08-23 IQ retro-flagged as DDR ramp; BEATFIX 148 image has NO tap
  structurally — leg 2 needs e49c011b on 148 = operator gate).

## Next actions (in rough priority)

1. H-1 conviction: mu/underflow tap run in sim; then a fix (mu wrap) + sim
   A/B at ±15k; then decide the flash path for a fixed image (needs rebuild
   — tmr_attr_inject recipe applies for 146; fix likely belongs in BOTH
   boards' RX).
2. Examine the banked wdlog snapshots (H-6 — watchdog-escape mechanism).
3. H-8: saturated CP95 leg at the +20k default (~10 min rig).
4. H-5a: reverse LO sweep (reverse runs +2.4k; likely also improvable).
5. H-5b: bidirectional-collapse repro with pre-recovery log capture.
6. Operator gates parked: 148 image choice (BEATFIX vs tap for float leg 2);
   146 image standing (verify which is flashed FIRST, see above).

## Traps learned this session (do not re-learn)

- ADRV9002 live RX-LO retune perturbs TX (both receivers went 100% crc) —
  full re-arm only, LO set at calibration time.
- RX LO == TX LO exactly on one board = zero-IF DC feedthrough, carrier
  reset storm — always off-null (+20k proven).
- ~40% sync + 100% crc = ARMCAUSE false-FTS latch (cure: double-tap vs
  clean self-signal), NOT a channel measurement.
- `grep` on board daemon logs needs `-a` (binary byte after restarts makes
  grep emit nothing on stdout).
- Single-shot anyssh through command substitution can drop output — retry
  or compute board-side.
- gitignore is last-match-wins: negations must FOLLOW the ignoring rule.
- Watcher loops must not pgrep patterns present in their own cmdline paths
  (the sentinel-swap deadlock).
