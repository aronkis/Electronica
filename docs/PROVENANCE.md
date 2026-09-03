# PROVENANCE — images, IDs, and configuration manifest

Single source of truth for **which `BOOT.BIN` is on which board, which kit built it,
and what it carries**. Build trees are gitignored, so this tracked file is how the
deployed image stays reproducible from version-controlled state. Image identity is
by the **BIST golden `cap_out=0x04922282`**, not md5 (md5 is not reproducible across
Vivado rebuilds).

## Current image (deployed on both boards)

| md5 | Kit | What | Deployed |
|---|---|---|---|
| **`dcf5c5fb29e6`** | `jupiter_byte_lean_build/` (`build_lean_image.sh`) | **The shipped image.** A LEAN debug-strip of P1E-v3: instrumentation removed (`QPSK_LEAN=1`; canary/state-pairs `0x160-0x16C` stripped) to restore ZU3EG timing margin, **keeping every fix** — `rxfix`, `resolver_lookback_fix`, `pifix`, `byte_rxfifo`, P1E-v3 tick compensation, dual-DMA tap (mux `0x10C` modes 0-3), P1D telemetry, DDS-diet. | **both boards, 2026-07-20** — acceptance PASS (preflight, `TAP_SMOKE_PASS`, BER rev ~2e-6 / fwd ~1.4e-4, `rstcs`~0). Rollback `/boot/BOOT.BIN.prelean` = v3 `0de4d5cb`. |

## Image lineage (development history)

The table below is the historical build lineage that led to the current image
(newest first). It is **history**, not the current deployment — see above.

| md5 (BOOT.BIN) | Size | Kit / build dir | Config | Where |
|---|---|---|---|---|
| `d06f67410d4d1000efd2269a564e2413` | 7203552 | `jupiter_byte_telemetry_build/` (fresh gates build + `bd_tap_dualdma ch1`) | everything in `58429a44…` **plus T8.7 state telemetry** (`canary3_telemetry_overlay.m`: mux mode 4 = 24-slot state broadcast of SS LF ×7 + IC packed + CS LF ×8 + AGC integrator ×4 + marker/counter; serializer port types pinned + DTC-SI isolation casts — the double-probe and back-prop fixes) **and mode 5 = CFC output tap** (`cfc_tap_overlay.m`, SS→CFC→CS bisect). Full 6-gate suite + PI_GATE PASS. Telemetry verified live: marker lock period-24, img counter gapless, data slots bit-exact vs in-fabric pipe invariant (csI==csD3 5000/5000). Known quirk: marker reads `0xA5C5FFEE` live (+5 hi16, marker-only; tel_parse accepts both). | **flashed both boards 2026-07-14 ~02:38** (supersedes `58429a44…`); first mode-4 session `hunt/20260714_024112_fwd` (6 events, telemetry+input rings) |
| `58429a449cf9f96ea8d7593f7925254e` | 7203552 | `jupiter_byte_t863_build/` (fresh gates build + `bd_tap_dualdma ch1`) | hardening + dual-DMA tap + T8.5 shadow + **T8.6.3 canary2** (`canary2_overlay.m`): path canary (4 graduated chains, 0x18C), **IC shadow with the leading-beat compensation** (`countReg` init 0.125; alignment proven by `tb_ic_align` 100k beats/0 mismatch on the regenerated netlist BEFORE build — supersedes the lying IC instrument on `b9955699…`/`6b612fb4…`), carrier-LF shadow (0x198/0x19C), strobe field {maxGap\|minGap}. Full 6-gate suite + PI_GATE PASS. **Zero-assert PASS post-lock: ALL seven canary regs 0x0 including IC (0x190/0x194) — every instrument truthful for the first time.** | **flashed both boards 2026-07-13 evening**; instrumented hunt session running |
| `a34233c5a3c24747ab1428afd7f3974d` | 7203552 | `jupiter_byte_ch2hard_build/` (from hard build via ch2 chain + `bd_tap_dualdma ch2` w/ explicit pack2 re-domain) | ch2 + hardening + dual-DMA tap; timing/BD/netlist verified (9/9 topology checks, IntegClamp present). **Wedge-testbed HW proof BLOCKED**: during testing (2026-07-12 ~13:00) the RX2 SSI receive path died on BOTH boards (adc_2_valid never strobes; forensic 0x15C duty=0; TX2 + rssi2 fine; survives cold boot) — the morning-golden `d32475cb…` config fails identically, so the image is exonerated (mid-day environmental/thermal, cf. the 2026-07-06 midday regression). ch1 re-verified working immediately after. Sim wedge proof (WEDGED→RECOVERED) stands. **Cool-down retest (same day ~15:10, after 75 min idle at the powered-idle floor 64/62°C — only ~2°C below failure-era temps): identical failure (forensic 0xFF00, no lock)** — inconclusive for the thermal hypothesis; the discriminating retest needs cooler ambient (overnight/early-morning) or a physical power cycle. | built 2026-07-12, in reserve; boards restored to `6ed649ba…` (locked try-1 both directions post-restore) |
| `a498d76d7428cf8aa0fc807cc88fd4f8` | 7203552 | `jupiter_byte_canary_build/` (fresh gates build + `bd_tap_dualdma ch1`) | hardening + dual-DMA tap + **T8.5 canary instrumentation** (`canary_instrumentation_overlay.m`): shadow timing loop (1-beat-offset exact copy; alignment RTL-proven 100k beats/0 mismatch), P-path/integrator divergence counters + latches, strobe forensic, beat counter — AXI 0x170–0x188. All 6 gates + PI_GATE PASS; S1B golden. First instrumented hunt (20260712_190124): **pdiv/idiv flat ZERO through ~300 episodes** → loop-filter registers NOT corrupted; random-register-corruption model rejected (see ERROR_TAXONOMY). Known: 0x184 strobe field rate-miscalibrated. Canaries also live-dissected a forward acquisition wedge (carrier variant: ingest clean + shadow aligned + junk constellation; rstCS-resistant, full re-arm clears — NCO-phase reset asymmetry CS:355 is the design-bug candidate). | **flashed both boards 2026-07-12 evening** (supersedes `6ed649ba…`, now in `.pretap`) |
| `6ed649badc9e862cef2213f69cc6ef4e` | 7203552 | `jupiter_byte_hard_build/` (fresh gates build + `bd_tap_dualdma ch1`) | dual-DMA tap + **T8.4 timing-loop anti-wedge hardening** (`timing_hardening_overlay.m`: IC Delta clamp ±127/1024, loop-filter IntegClamp ±0.06, DTC17 saturate). All 6 gates + PI_GATE PASS; wedge TB WEDGED→RECOVERED on the netlist; MODEL_GATE bit-identical. HW: TAP_SMOKE_PASS; acceptance rev **1.95e-6** / fwd 1.70e-4 (baseline-equal); Class-1 episode severity unchanged (hardening targets Class-4 acquisition wedge). | **flashed both boards 2026-07-12**; backups `/boot/BOOT.BIN.pretap` (hold `6b1b4409…`) |
| `6b1b4409017dd5408c6bcaeeae66b20c` | 7203552 | `jupiter_byte_tap_build/` (+ `bd_tap_dualdma.tcl ch1`) | **DUAL-DMA tap** (supersedes `4a0e7e22…`): rx-lpc voltage0 = receiver input (legacy Tap-A), **rx2-lpc voltage0 = iq_debug_mux stream** (0x10C: 0 AGC-out/1 postSS/2 postCS/3 constellation) — the adrv9002 driver exposes one pair per device, so the tap rides the rx2 DMA (pack2+rx2-DMA moved to the adc_1 composite domain). State regs 0x160/0x164 live; 0x168/0x16C latch 0 (known model-level probe wiring; redundant with mux 2/3). Baseline regression on the tap datapath: rev 2.27e-6, fwd 2.02e-4 (within spread). | **flashed both boards 2026-07-12**; backups `/boot/BOOT.BIN.pretap` (hold `4a0e7e22…`, datapath-identical to pifix) |
| `d32475cb1f4230178f13389950ee61f9` | 7203552 | `jupiter_byte_ch2tap_build/` (project copy of tap build + BD retarget + dual-DMA) | ch1+tap source **retargeted to ADRV9002 channel 2** (`bd_ch2_rewire` → `bd_ch2_reset` → `ch2_fix_ch1_bdonly` → `bd_ch2_tapfix` → `bd_tap_dualdma ch2`): modem on adc_2/dac_2, byte path + both capture packs in the adc_2 clock domain, ch1 restored as plain DMA. Same host-visible tap layout as the ch1 image: rx-lpc voltage0 = receiver input, rx2-lpc voltage0 = mux stream. CH2 attrs: TX2 LO `out_altvoltage3`, RX2 LO `out_altvoltage1`, `*_voltage1_*`, DAC-mux regs on `tx2-lpc` (harnesses via `ch2ify.sh`). Netlist: 286 StatePairProbe + 36 debug-mux cells; intra-clock timing all met. Supersedes `e27509c9…` (pre-dual-DMA, never flashed). | **A/B run 2026-07-12: ch1 adopted, ch2 in reserve.** Forward (146 TX2→148 RX2) locked instantly every arm; reverse (148 TX2→146 RX2) hit the Class-4 symbol-sync wedge ~9/10 arms (tap-dissected: input float-perfect, AGC-out clean, postSS frozen, constellation zero; see ERROR_TAXONOMY Class 4). One locked reverse window ran 1.3e-4 (no win vs ch1). All four ch2 RF legs verified cabled (rssi/DDS probes). Boards restored to `6b1b4409…` from `/boot/BOOT.BIN.prech2`. NOTE: the agpio4-7 arm writes are load-bearing for lock on BOTH channels. |
| `4a0e7e221e287581121069824cf0e569` | 7203552 | `jupiter_byte_tap_build/` (pre-dual-DMA) | first-generation tap image: mux + state regs verified in netlist, but the tap pair rode pack ch2/3 (voltage1) which the adrv9002 driver never exposes — tap unstreamable. Datapath identical to pifix. | superseded by `6b1b4409…`; lives on both boards as `/boot/BOOT.BIN.pretap` |
| `5c85af2cf62d25c6c0b4d350e2944019` | 7203552 | `jupiter_byte_pifix_build/` (from `jupiter_240k5_byte/`, clone) | rxfix + resolver_lookback_fix + **pifix** (pi-shadowing fixed: demod boundary back to the 45° grid — was skewed 30.68°, the ~2–3e-3 OTA floor — and carrier-sync loop gains back to design 98, was 3.14× hot 307; PI_GATE added). All 6 gates + PI_GATE PASS; capture-replay at FLOAT PARITY (floor_148 8.9e-3→0, esrc 2.0e-3→0). | **flashed on both boards 2026-07-11** (148 then 146); backups `/boot/BOOT.BIN.prepifix`. HW: reverse 1.4–2.1e-6 (goal met); forward 1.06e-4 gain-pinned / ~2e-4 auto — live RF effect, see `two_jup/FLOAT_FIXED_CAMPAIGN.md` |
| `8d6b82ff597e52aa0941a3ab536a30b7` | 7203552 | `jupiter_byte_rxfix_build/` (from `jupiter_240k5_byte/`) | K5 byte modem + **rxfix** (`CFOChangeDetectThreshold=0.0125`) + **resolver_lookback_fix** — CARRIES the pi-shadowing poisoned demod/CS constants | superseded by pifix; backup `/boot/BOOT.BIN.prerxfix` |
| `447caa20736aac3d8f37dccc62a92077` | 7203552 | `jupiter_byte_build/` | K5 byte modem, **pre-rxfix** (`CFOChangeDetectThreshold=0.0015625`) | superseded (was the flooring image on 148) |
| `f351ad874b74bea11561b384b41266ea` | 7203552 | `jupiter_byte_verify_build/`, built **standalone from the clone** | rebuild of the rxfix source (reproducibility check, 2026-07-10) | not deployed — **functionally equivalent** to `8d6b82ff…`: all 6 gates PASS, S1B/BIST golden `cap_out=0x04922282`. An earlier rebuild in `qpsk_variants` gave `121fac403264…`. |

> **md5 is not reproducible across Vivado rebuilds** (place/route + `bootgen`
> timestamps). Three builds of the *same source* gave three md5s — `8d6b82ff…` (shipped),
> `121fac403264…` (rebuild in `qpsk_variants`), and `f351ad874b74…` (standalone rebuild from
> a fresh clone) — all functionally equivalent; equivalence is by the gates + BIST golden,
> not md5. The clone builds end-to-end on its own (relativized paths, verified 2026-07-10).
> See [BUILD.md](BUILD.md).

## The two fixes in the shipped image

| Fix | Locus | Value / commit | Effect (live) |
|---|---|---|---|
| CFO reset-storm ("rxfix") | `jupiter_240k5_byte/commhdlQPSKTxRxParameters.m:45` | `0.0015625 → 0.0125` | `rstcs` 52/s → 0; frame yield 40% → 93.5% |
| Phase-ambiguity resolver | `resolver_lookback_fix` via `assemble_jupiter_240k5_byte.m` | git `8033363` | byte plane carries arbitrary data 99.9% on HW |

## Gate evidence (tracked stamps in `jupiter_240k5_byte/`)

The build gates each drop a stamp file; these are the "green build" evidence:
`SIM_BYTE_GATE_K5.txt` (model oracle), `CHECKHDL_240K5_BYTE.txt` (checkhdl+makehdl),
`S1_GATE.txt` (ROM iverilog, per-frame `cap_out=04922282`), `S1B_GATE.txt` (byte
Verilator rot0/rot17 PASS). The golden BIST readback throughout is `cap_out = 0x04922282`.

## Stage-naming key (reconciles three conventions across the docs)

Different docs use different stage letters for the same journey — this is the map:

| Convention | Where | Meaning |
|---|---|---|
| **S0–S3** | the 2026-07-04 two-Jupiter FDD link plan (superpowers plan, local disk — not tracked) | S0 preflight/reflash · S1 DDS-tone channel verify · S2 modem deploy · S3 bring-up to <0.01% |
| **S1–S6** | `plans/2026-07-01-bidir-240k-k5-plan.md` | S1 sim · S2 build · S3 deploy · S4 offline-air · S5 on-chip BIST · S6 FDD soak |
| **S1 / S1B / G1 / G2** | `jupiter_240k5_byte/README_BYTE.md` | build netlist gates (S1 ROM, S1B byte) + HW gates (G1 BIST-on-air, G2 arbitrary-data) |


- `dcf5c5fb29e6` | 7203552 | jupiter_byte_lean_build | **CURRENT SHIPPED.** LEAN debug-strip of v3: HDL debug logic removed (adc_forensic/canary/p1b state-pairs 0x160-0x16C stripped; `QPSK_LEAN=1` gates) to restore ZU3EG placement/timing margin, while KEEPING the shipped fixes (rxfix, resolver, pifix, byte-rxfifo) + P1E-v3 tick-compensation + dual-DMA tap (mux modes 0-3, 0x10C) + P1D telem. Carries the DDS-diet. On a non-ticking board the v3 compensation is a no-op. | **DEPLOYED both boards 2026-07-20** (staged via `deploy_image.sh`); acceptance: preflight PASS both, TAP_SMOKE_PASS (LEAN mode), BER rev ~2e-6 / fwd tick footprint MISS 0.4% unchanged, rstcs ~0. Rollback = `/boot/BOOT.BIN.prelean` (holds v3 `0de4d5cb`).
- `0de4d5cba0af` | 7203552 | jupiter_byte_p1e2_build | v3 tick-compensation (acc-position arm qualifier accOff<=530) + P1D telem + dual-DMA tap + DDS-diet | superseded by the lean image 2026-07-20; retained as the `/boot/BOOT.BIN.prelean` rollback on both boards. DEPLOYED 2026-07-19; hardware-verified (hunt 20260719_065300, no regression, arm census armable_frac=1.00)

## Historical image IDs (lab lineage)

Catalogued in `docs_session/qpsk-two-board-link-state.md` (running lab log). Notable:
`8841bbae` (K=7 Jupiter FEC composite, `fec_dut`), `494122c1` (t8final G1), `753760ad`
(gather+AGC cable-proven), `e7c3b10c` (ZedBoard FEC-Tx), `b81bf7d22428` (`zed_msggenrom`),
`e508dd01d50b` (`jupiter_msggenrom`), `7ef33246` (cfc12 baseline). These are archived
lineages, not the current modem.
