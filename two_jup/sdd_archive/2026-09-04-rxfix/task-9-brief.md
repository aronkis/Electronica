# Task 9 — RXFIX_W1: silicon ring-witness instrument for 148 (desk + build, NO flash)

## Why
The sim's loss mechanism is unsettled (tiled-stimulus artefact suspected; ring-lap mechanism withdrawn; R1/R2/R3 dead). The silicon facts stand: one-sided symbol deletion every ~32 frames at 2.5 ppm, TX clean, loopback lossless. The next decisive evidence is on silicon: TRUE Rate_Handle ring occupancy, pop_on_empty and push_on_full counts, and a per-stage valid census, read on 148 during a live forward leg. Task 7's report §6 (two_jup/sdd_archive/2026-09-04-rxfix/task-7-report.md) is the design source; read it first.

## Deliverables
1. **Ownership check [netlist]**: in the SEQBIST kit tree that produced the flashed 148 image a1ff3c876d91 (two_jup/skidfix/jupiter_byte_seqbist_kit.sh → its build dir), confirm who decodes 0x20C/0x210 (DBGCAP per QPSK_Rx.v:681-690 and Task 3's finding). Record the addr_decoder lines.
2. **Injector variant `RXFIX_W1`** in two_jup/skidfix/rxfix_inject.py (same shape as R1–R3: exactly-once anchors, per-variant marker, all 3 loose mirrors + both TxRxCompo_ip_v1_0.zip members + verify_zip, --sim-tree, tests): 
   - re-expose Rate_Handle `witA` = {true occupancy (Delay_out1, 6 bits), push_ptr, pop_ptr} and `witB` = {push_on_full_count[15:0], pop_on_empty_count[15:0]} at two FREE AXI read addresses (find free ones in TxRxCompo_ip_addr_decoder.v; do not touch 0x20C/0x210; do not touch write-only regs 0x158/0x114/0x118/0x10C/0x208);
   - per-stage valid census: 32-bit valid counters at (a) Symbol_Synchronizer strobe, (b) Rate_Handle validOut, (c) CFC out, (d) Carrier_Synchronizer out, (e) Preamble_Detector out, (f) Packet_Controller out, exposed through FREE cnt_mux32 slots (rx_seq_checker owns 16–31; confirm 0–15 usage in wrap/QPSK_Rx) with the existing freeze discipline (tgen_rx ctrl bit 3); if cnt_mux32 has no free slots, add a second cnt_mux32 on a free select field and say so;
   - optional if cheap: ddrcap_sel = 12 carrying {occupancy, push_ptr}/{pop_ptr, edge_event} at enb rate (TxRxComposite.v:2011-2033). Skip if it threatens WNS.
   - Cost ceiling: a few hundred LUTs, nothing on the critical path; no change to the data path (s=0 bit-identity on the sro harness is a gate).
3. **Sim gate** on the sro harness (jupiter_240k5_byte/rtl_sim/wrap_byte_sro.v / sim_sro.cpp): at 0 ppm the data path is byte-identical to baseline; the witness words and census counters read back equal to the harness taps (occupancy, pop_on_empty, push_on_full, per-stage valid counts) over a tiled −10 ppm leg (edge events present). Exit-gated scoring; results to two_jup/comb/RXFIX_W1_SIM_GATE.md.
4. **Kit + build**: `two_jup/skidfix/jupiter_byte_rxfix_kit.sh` derived from jupiter_byte_seqbist_kit.sh (checker retained), applying RXFIX_W1 only; build on hdl-dev-2 with build_txfix.sh, IMPL_STRATEGY=explore, routed-WNS gate (WNS < 0 → report, do not bank as flashable). Run the build as a systemd-run --user unit (-p WorkingDirectory=…), never a harness background job; watcher writes HEARTBEAT lines.
5. **Bank** boot_known_good/BOOT.BIN.148.rxfixw1.<md5> + a register map file two_jup/rxfix/W1_REGMAP.md (address, field, width, freeze semantics) + a reader script two_jup/rxfix/w1_read.sh (ssh devmem, once per 10 s, never faster, K=V env, DRY tests with the ssh shim like witness_read.sh).
6. **STOP before any flash.** Report DONE with the md5, WNS, and the reader; the controller schedules the flash under rails.

## Rails
- No board contact at all in this task (no ssh to 10.0.0.148/146 except a read-only `md5sum` of the flashed image if needed for item 1, and even that is optional — the banked file's md5 is the same).
- Never edit a script a live systemd unit runs. Task 7's t7* units and its files under two_jup/comb/sro_sim/ are not yours to modify; add new files.
- Labels [silicon]/[sim]/[netlist]/[inferred]. Commit `git commit -s` with trailer `Claude-Session: https://claude.ai/code/session_019NZLGbxoaPRkDnKFMPiBrq`; commit implies push (branch per-under-1pct-2026-07).
- HEARTBEAT task9 <ISO> <state> to two_jup/sdd_archive/2026-09-04-rxfix/progress.md at least every 5 minutes, including while parked on the build (use a heartbeat unit like Task 7's t7hb). Ledger lines start with `Task 9:`.
- No subagents. Report file: two_jup/sdd_archive/2026-09-04-rxfix/task-9-report.md. Return only status, commits, one-line test summary, concerns.
