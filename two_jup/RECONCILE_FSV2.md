# RECONCILE_FSV2 — e49c011b (lean) vs f2e22135 (fsv2): the full input/output diff
# (2026-08-13, build-only session; pre-wit3-rebuild reconciliation)

## VERDICT: there is NO rate-breaking delta in the fsv2 build inputs or outputs.
The two images' fabric is rate-IDENTICAL. Every suspect the routing note named
(env drift, the Aug-05 cadence contract "on the wrong side", the FsAgcRT rate
domain, a wrong-rate witness counter tap halving a rail) was checked against the
as-built artifacts and is CLEAN. The half-rate health reading on silicon cannot
be explained by the netlist, the BD, or timing closure — evidence below — and
its signature (partial decode, not zero decode) is not what a rail/cadence break
produces. The wit3 rebuild is therefore a *clean-execution* rebuild of the same
witness content on the proven lineage, gated by a new static rate-parity check,
NOT a source fix.

## Evidence matrix (all paths absolute, all diffs run this session)

| Input / output | lean e49c011b (18:03/19:56) | fsv2 f2e22135 (21:29/00:00) | delta |
|---|---|---|---|
| env (matlab log banners) | LEAN, f1536, sps=4, thr=0.0125, FRAMESTAT | identical | none |
| rate_240k_overlay | "Rsym*sps rail = 1.536e+07, sps = 4" | identical line | none |
| ss8/timing/agc/fec/taps overlay banners | full chain | identical | none |
| framestat_overlay | wordcnt 0x1C0 only | + stall 0x1C4, txur 0x1C8, bits [9]/[10] | THE witness delta (aff4183) |
| a3f1902 FsAgcRT | absent from build dir | absent from build dir (regen started 21:14, commit 21:22) | none — and inert under LEAN anyway (guarded on adc_forensic port, absent in LEAN) |
| `TxRxCompo_ip_src_TxRxComposite_tc.v` (timing controller) | — | — | **byte-identical except Created timestamp** |
| Rate table (composite header) | base 3.25521e-08, ce_out_0/1 | identical rails; new ports: stallcnt ce_out_1 (same as wordcnt), txurcnt ce_out_0 | rails unchanged |
| hdlsrc file set | — | +FrameStatStallCnt.v, +FrameStatTxUrCnt.v only | witness only |
| Changed shared files | — | ByteBitShifter/Input_Data/Transmitter/TxInterleaveK5/Composite/Probe/ip/dut/axi_lite/addr_decoder | ALL witness port plumbing + a temp-var rename (p58→p59); every touched instance keeps its enable (ByteBitShifter enb_1_2_0 both; probe enb_1_2_0 both; stall counter enb+valid&&!ready mirrors the PRE-EXISTING wordcnt wiring exactly) |
| addr decoder | — | +0x1C4/+0x1C8 read cases appended; all prior addresses untouched | none |
| `system.bd` (post-dualdma, json-normalized) | — | — | **identical except ip_revision + mem_init path** |
| Vivado flow | build_cyclic_image.sh → dualdma ch1 → clear_incr → ch2_build2 | same scripts, same order | none |
| Ship timing gate | TIMING_GATE_WNS modem_dut=2.874; CH2_IMPL_WNS 0.359 | modem_dut=2.874; CH2_IMPL_WNS 0.160 | both PASS |
| Implemented timing summary | WNS 0.359 / WHS 0.006 / TNS,THS 0, 320959 EP | WNS 0.160 / WHS 0.010 / TNS,THS 0, 322765 EP | both clean; +1806 endpoints = the witness logic IS in the shipped fsv2 bitstream |
| Build execution | single pass, 18:03→19:56 | **impl CRASHED 22:11 and 22:30 (machine memory pressure: 12G free vs 32G), hand-resumed twice**, then dualdma+ch2 full-resynth to 00:00 | the ONLY execution divergence; ch2_build2 resets all runs so the shipped netlist is a clean resynth regardless |

## Why the named suspects are dead
- **Aug-05 cadence contract flipped in fsv2**: impossible — the entire RX chain
  (Receiver/*, Symbol Sync, CFC, Interpolation Control) is in the UNCHANGED file
  set; the composite input handling shows zero diff lines; the tc.v is
  byte-identical. HARNESS_AB's module-diff already found the same. And fsv2
  scores 73/78 real-IQ at cadence 2 (its silicon-native pacing) — a netlist that
  consumed at the wrong cadence could not do that.
- **FsAgcRT (a3f1902) wrong rate domain**: not even in the fsv2 build dir (the
  build rsynced KIT at 21:14, the fix landed 21:22), and its branch is guarded
  on the adc_forensic outport, which LEAN builds don't have. Its RT is also
  rate-correct (OutPortSampleTime 1/15.36e6 = ce_out_0) for the non-LEAN case.
- **Witness counter tap halving a rail via scheduler back-prop**: the stall
  counter is wired token-for-token like the PRE-EXISTING 0x1C0 wordcnt
  (.vld(valid), .rdy(byte_rx_ready), enb) that e49c011b runs at full rate; the
  txur counter sits on ce_out_0 like the probe. No new rate appears anywhere
  (rate table has the same two ce's) and the timing controller is unchanged.

## Re-reading the silicon evidence
Health gate on fsv2 (proper bring-up): fsync=573/s, wordcnt=493 f/s vs nominal
~1245. A rail/cadence-broken receiver produces ~ZERO decodes (sps pacing wrong →
sync loops never lock — the sim cadence-4 experiment delivered 5/78 with huge
biterr), not 46% steady throughput. 573/s is a *throughput throttle* signature
(byte-plane consumption/DMA duty cycle, bring-up/watchdog interaction), which is
host-visible-state dependent, not fabric-rate dependent. That reconciles the
contradiction the routing note flagged ("sim 73/78 yet half rate on silicon"):
both observations are consistent with a rate-correct fabric.
NOTE this does NOT clear f2e22135 for flashing — the operator's no-retry rail
stands; it means the witness content is not the culprit, and the clean wit3
rebuild + parity gates below are the correct next instrument.

## What wit3 changes vs fsv2
1. Same KIT witness content (aff4183 + a3f1902, both committed) — no source fix
   is warranted by the evidence.
2. Clean single-pass Vivado execution on an idle machine (49G free) — removes
   the crash/resume divergence, the only execution-level difference found.
3. NEW static gate `jupiter_240k5_byte/static_rate_parity_gate.sh`: asserts
   timing-controller byte-parity, rail-table parity, and BD parity against the
   banked e49c011b lineage build, so any future scheduler/rail regression is
   caught before bitgen — the check this reconcile performed by hand, made
   permanent.
4. Replay gate at the fixed cadence contract (CAD=2) with the ≥73/78 bar
   (HARNESS_AB re-anchor caveat applies: reference's own score is 74).
