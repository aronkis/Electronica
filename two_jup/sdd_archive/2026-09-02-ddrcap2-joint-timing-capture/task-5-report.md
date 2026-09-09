# Task 5 Report: DDRCAP-v2 build on hdl-dev-2, bank

## Step 1: build tree + injectors
```
rsync -a --exclude 'hdl_prj_jupiter_composite/vivado_ip_prj/vivado_prj.runs/' --exclude '*.log' --exclude '*.jou' \
      jupiter_byte_txmark_build/ jupiter_byte_ddrcap2_build/
sed -i "s|jupiter_byte_ddrcap_build|jupiter_byte_ddrcap2_build|g" jupiter_byte_ddrcap2_build/build_ddrcap.sh
```
`REMOTE_DIR`/`REMOTE_DIR_EXPANDED` after sed:
```
REMOTE_DIR='~/qpsk-builds/jupiter_byte_ddrcap2_build'
REMOTE_DIR_EXPANDED=/home/tcollins/qpsk-builds/jupiter_byte_ddrcap2_build
```
Both confirmed retargeted at `jupiter_byte_ddrcap2_build`.

v1 injector (`TXMARK=1 python3 two_jup/skidfix/ddrcap_inject.py jupiter_byte_ddrcap2_build`):
```
    zip member TxRxCompo_ip_src_Transmitter.v                already  (TxRxCompo_ip_v1_0.zip)
    zip member TxRxCompo_ip_src_TxRxComposite.v              already  (TxRxCompo_ip_v1_0.zip)
    zip member TxRxCompo_ip.v                                already  (TxRxCompo_ip_v1_0.zip)
    VERIFY_OK jupiter_byte_ddrcap2_build/hdl_prj_jupiter_composite/vivado_ip_prj/ipcore/TxRxCompo_ip_v1_0.zip
DDRCAP_INJECT loose_files=9 logical_groups_satisfied=8/8 zip_members_patched=18 zips_verified=2/2
```
All members "already" (v1 pre-applied to the txmark lineage), VERIFY_OK x2 as expected.

v2 injector (`python3 two_jup/skidfix/ddrcap2_inject.py jupiter_byte_ddrcap2_build`):
```
    VERIFY_OK jupiter_byte_ddrcap2_build/hdl_prj_jupiter_composite/ipcore/TxRxCompo_ip_v1_0/TxRxCompo_ip_v1_0.zip
  zip jupiter_byte_ddrcap2_build/hdl_prj_jupiter_composite/vivado_ip_prj/ipcore/TxRxCompo_ip_v1_0.zip
    ...
    VERIFY_OK jupiter_byte_ddrcap2_build/hdl_prj_jupiter_composite/vivado_ip_prj/ipcore/TxRxCompo_ip_v1_0.zip
DDRCAP2_INJECT loose=7 missing=[] zips=2 zips_verified=2
```
`missing=[] zips=2 zips_verified=2` — gate satisfied, cleared to launch.

## Step 2: launch and watch
Launched from nemo:
```
DDRCAP_BUILD sync start 2026-09-02T15:19:12-04:00
DDRCAP_BUILD sync done 2026-09-02T15:19:26-04:00
Running as unit: ddrcap-build-1788376766.service; invocation ID: 7753b295e7404ef7a6d0f102cc93978f
DDRCAP_UNIT ddrcap-build-1788376766 started 2026-09-02T15:19:26-04:00
DDRCAP_BUILD launched on hdl-dev-2 as unit ddrcap-build-1788376766 ; remote tree: /home/tcollins/qpsk-builds/jupiter_byte_ddrcap2_build
```
`jupiter_byte_ddrcap2_build/LAUNCHED` written immediately after with the launch line, per instructions.

Bounded checks (ssh tail + ls), each ~5 min apart:
- 15:24:38 — synth_1 launched, waiting to finish
- 15:29:49 — netlist sorting / Unisim transformation complete (synth in progress)
- 15:34:56 — Start Timing Optimization
- 15:40:02 — open_run done, TIMING_GATE clock analysis
- 15:45:09 — Phase 2.4 Global Place Phase1
- 15:50:15 — license obtained for Implementation, Initial Update Timing Task starting
- 15:55:22 — global placement overlap resolution (5334 -> 2193 -> 967 nodes)
- 16:00:28 — placement clean (0 overlaps); route intermediate timing WNS=0.105 TNS=0.000 (WHS/THS negative mid-route, expected transiently)
- 16:05:28 (final independent verification) — unit no longer present (`systemctl --user status` reports "could not be found", i.e. finished/collected); log tail shows bitstream write complete, `Bitgen Completed Successfully`, `196 Infos, 2 Warnings, 0 Critical Warnings and 0 Errors encountered`, `BYTE_BUILD_DONE md5=638b36de3493b409fb8db7859b00898f  BOOT.BIN`, Vivado exited 16:04:14.

Wall time: launch 15:19:26 -> build done ~16:04:14 => **~44.8 min**.

`grep -c 'ERROR:' build_ddrcap_vivado.log` = **0**.

Timing summary lines (final):
```
INFO: [Route 35-416] Intermediate Timing Summary | WNS=0.105  | TNS=0.000  | WHS=0.010  | THS=0.000  |
INFO: [Route 35-57] Estimated Timing Summary | WNS=0.105  | TNS=0.000  | WHS=0.010  | THS=0.000  |
```
WNS/TNS/WHS/THS all non-negative — timing met. No "ERROR:" lines in the log.

BOOT.BIN on hdl-dev-2: 7,203,552 bytes at `~/qpsk-builds/jupiter_byte_ddrcap2_build/hdl_prj_jupiter_composite/vivado_ip_prj/boot/BOOT.BIN`, matching the required size exactly.

## Step 3: fetch, verify, bank
```
scp hdl-dev-2:.../boot/BOOT.BIN jupiter_byte_ddrcap2_build/hdl_prj_jupiter_composite/vivado_ip_prj/boot/BOOT.BIN
```
Local copy: 7,203,552 bytes, md5 `638b36de3493b409fb8db7859b00898f` — matches the remote build log's `BYTE_BUILD_DONE md5=` line exactly (bit-for-bit transfer confirmed).

Banked as `boot_known_good/BOOT.BIN.148.ddrcap2.638b36de3493`.

`md5sum -c MD5SUMS` result: the new entry `BOOT.BIN.148.ddrcap2.638b36de3493: OK`. One **pre-existing, unrelated** failure was present in MD5SUMS before this task touched it: `BOOT.BIN.148.rxfifo4k_v5debug.602b26c25c35: FAILED open or read` (that banked file is simply not present on disk — unrelated to this build; not introduced by this task).

README row appended exactly as specified (marked NOT yet flashed).

## Files changed / committed
- `boot_known_good/MD5SUMS` (appended one line)
- `boot_known_good/README.md` (appended one row)
- `jupiter_byte_ddrcap2_build/build_ddrcap.sh` (force-added; directory is gitignored by `jupiter_byte_*_build/`)
- `jupiter_byte_ddrcap2_build/launch.log` (force-added, same reason)

Not committed: `BOOT.BIN` (banked directory only), rest of the build tree (gitignored, as intended).

Commits:
- `a846b0e` — "DDRCAP2 image built and banked: BOOT.BIN.148.ddrcap2.638b36de3493" (MD5SUMS, README.md)
- `bb59345` — "Add ddrcap2 build launch script and log (banked image a846b0e)" (build_ddrcap.sh, launch.log — required `git add -f` since `jupiter_byte_*_build/` is gitignored)

## Concerns
1. `.gitignore` has a blanket rule `jupiter_byte_*_build/` that would have silently skipped `build_ddrcap.sh` and `launch.log` on a plain `git add`; force-added per the explicit brief instruction. Worth checking whether this ignore-then-force-add pattern is intended repo convention or whether the ignore rule should carve out an exception (the sibling `jupiter_byte_txmark_build/` and `jupiter_byte_ddrcap_build/` trees have no tracked files at all, so this is the first instance of this pattern).
2. Pre-existing unrelated `md5sum -c` failure for `BOOT.BIN.148.rxfifo4k_v5debug.602b26c25c35` (file missing on disk) was present in MD5SUMS before this task and is not something this task caused or fixed.
3. Image is explicitly **NOT yet flashed** — no board/link action was taken, per task scope (nemo + hdl-dev-2 only).
