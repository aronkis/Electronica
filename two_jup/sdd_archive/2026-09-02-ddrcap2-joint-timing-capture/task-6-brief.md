### Task 6: 148-only flash chain with rails — script, dry-run, then the flash (operator go at Step 4)

**Files:**
- Create: `two_jup/skidfix/flash_148_ddrcap2.sh`
- Modify: `two_jup/tests/fake_anyssh.sh` (add the cases the chain uses)

**Interfaces:**
- `flash_148_ddrcap2.sh <md5-12>` with env `DRY=1` (echo every board command instead of running it). Rails per Global Constraints. Rollback target `1cd0cd752aa6`.

- [ ] **Step 1: Write the chain**

```bash
#!/bin/bash
# flash_148_ddrcap2.sh <md5-12> -- flash 148 with the DDRCAP-v2 image under the standing rails,
# adapted to the 148-ONLY mode-1 campaign (146 is never touched): bring-up + gate = arm148_mode1.sh x2.
#   [1] preconditions: sentinel stopped; current image = 1cd0cd752aa6; on-board rollback copy verified
#   [2] stage + flash (size-checked), reboot, wait back
#   [3] readback md5 == expected, else ROLLBACK
#   [4] two-pass gate: arm148_mode1.sh ARM_OK with fps>=1120 and golden capTAP, twice; else ROLLBACK
#   [5] Tier-2 witness: one 4 MB sel-6 capture decoded with ddrcap2_decode.py --summary, read BEFORE any rollback
#   NO retry loop. Rollback = restore /boot from the on-board copy, reboot, arm148_mode1.sh once, stop.
set -u
ROOT=/mnt/onetb/scratch/qpsk-jupiter-modem; D=$ROOT/two_jup; W=$D/anyssh.sh; A=10.0.0.148
EXP=${1:?usage: flash_148_ddrcap2.sh <md5-12>}; BAK=1cd0cd752aa6
BB=$ROOT/boot_known_good/BOOT.BIN.148.ddrcap2.$EXP
DRY=${DRY:-0}; LOG=$D/skidfix/ddrcap2_flash_$(date +%Y%m%d_%H%M%S).log
say(){ echo "$(date +%T) $*" | tee -a "$LOG"; }
brd(){ if [ "$DRY" = 1 ]; then echo "[dry] $*"; else $W $A "$@" 2>/dev/null | tr -d '\r'; fi; }
scpput(){ if [ "$DRY" = 1 ]; then echo "[dry] scp $*"; return 0; fi
  SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no "$@" </dev/null 2>/dev/null; }
wait_back(){ [ "$DRY" = 1 ] && return 0; sleep 45; local n=0; until ping -c1 -W2 $A >/dev/null 2>&1; do sleep 5; n=$((n+5)); [ $n -gt 240 ] && return 1; done; sleep 20; return 0; }
gate(){ local o; o=$(bash $D/arm148_mode1.sh 2>&1); echo "$o" | tail -2 | tee -a "$LOG"
  echo "$o" | grep -q ARM_OK || return 1; local f; f=$(echo "$o" | sed -n 's/.*fps=\([0-9]*\).*/\1/p' | tail -1); [ "${f:-0}" -ge 1120 ]; }
rollback(){ say "=== ROLLBACK to $BAK (rail: no retry) ==="
  brd "cp -f /root/BOOT.BIN.$BAK.bak /boot/BOOT.BIN && sync && md5sum /boot/BOOT.BIN | cut -c1-12"
  brd 'sync; (sleep 1; reboot) &'; wait_back || { say "FLASH_DDRCAP2_FATAL: 148 not back after rollback -- PHYSICAL ATTENTION"; exit 2; }
  say "  rollback booted: $(brd 'md5sum /boot/BOOT.BIN | cut -c1-12') (expect $BAK)"; gate || say "  WARN: post-rollback arm not ARM_OK -- operator"
  rm -f ~/modem-status/SENTINEL_STOP; say "FLASH_DDRCAP2_ROLLED_BACK"; exit 1; }

say "=== [1/5] preconditions ==="
[ -f "$BB" ] && [ "$(md5sum "$BB" | cut -c1-12)" = "$EXP" ] || { say "FATAL: $BB missing or md5 != $EXP"; exit 1; }
touch ~/modem-status/SENTINEL_STOP; say "  sentinel stopped (SENTINEL_STOP)"
CUR=$(brd 'md5sum /boot/BOOT.BIN | cut -c1-12'); say "  148 current image: $CUR (expect $BAK)"
[ "$DRY" = 1 ] || [ "$CUR" = "$BAK" ] || { say "FATAL: current image is not the banked restore point"; rm -f ~/modem-status/SENTINEL_STOP; exit 1; }
brd "[ -f /root/BOOT.BIN.$BAK.bak ] || cp -f /boot/BOOT.BIN /root/BOOT.BIN.$BAK.bak; md5sum /root/BOOT.BIN.$BAK.bak | cut -c1-12" | tee -a "$LOG" | grep -q "$BAK" || [ "$DRY" = 1 ] || { say "FATAL: on-board rollback copy bad"; rm -f ~/modem-status/SENTINEL_STOP; exit 1; }
say "=== [2/5] stage + flash ==="
scpput "$BB" root@$A:/root/BOOT.BIN.staged
FL=$(brd 'NB=$(stat -c %s /root/BOOT.BIN.staged 2>/dev/null||echo 0); if [ "$NB" -gt 6000000 ]; then cp -f /root/BOOT.BIN.staged /boot/BOOT.BIN && sync && echo "FLASHED $(md5sum /boot/BOOT.BIN|cut -c1-12)"; else echo "ABORT staged=$NB"; fi')
say "  $FL"; echo "$FL" | grep -q FLASHED || [ "$DRY" = 1 ] || { say "FATAL: flash did not complete; /boot untouched"; rm -f ~/modem-status/SENTINEL_STOP; exit 1; }
brd 'sync; (sleep 1; reboot) &'; wait_back || rollback
say "=== [3/5] readback verify ==="
BOOT=$(brd 'md5sum /boot/BOOT.BIN | cut -c1-12'); say "  booted image: $BOOT (expect $EXP)"; [ "$DRY" = 1 ] || [ "$BOOT" = "$EXP" ] || rollback
say "=== [4/5] two-pass gate (arm148_mode1: ARM_OK, fps>=1120, capTAP golden) ==="
gate || rollback; gate || rollback; say "  GATE_PASS x2"
say "=== [5/5] Tier-2 witness (read BEFORE any rollback): sel6 4 MB, decoded ==="
brd "echo enabled > /sys/bus/iio/devices/iio:device0/reg_access; echo '0x10C 0x60003' > /sys/kernel/debug/iio/iio:device0/direct_reg_access; sleep 1; cd /tmp && rm -f w.bin && iio_readdev -b 4096 -s 1048576 axi-adrv9002-rx2-lpc voltage0_i voltage0_q > /tmp/w.bin 2>/dev/null; stat -c %s /tmp/w.bin"
[ "$DRY" = 1 ] || { $W $A 'cat /tmp/w.bin' > "$D/skidfix/ddrcap2_witness_$EXP.bin" 2>/dev/null; python3 "$D/ddrcap2_decode.py" "$D/skidfix/ddrcap2_witness_$EXP.bin" --summary | tee -a "$LOG"; }
rm -f ~/modem-status/SENTINEL_STOP; say "FLASH_DDRCAP2_OK $EXP (sentinel released)"
```

- [ ] **Step 2: Dry run + lint**

```bash
cd two_jup && bash -n skidfix/flash_148_ddrcap2.sh && shellcheck -S warning skidfix/flash_148_ddrcap2.sh || true
DRY=1 bash skidfix/flash_148_ddrcap2.sh $(ls boot_known_good/ 2>/dev/null | sed -n 's/BOOT.BIN.148.ddrcap2.\(.*\)/\1/p' | head -1) 2>&1 | tail -20
```
Expected: every board action printed as `[dry] ...`, the sequence [1]..[5] in order, no FATAL (DRY skips the md5 equality checks by design, printed as such), `FLASH_DDRCAP2_OK`. `SENTINEL_STOP` must not remain afterwards (`ls ~/modem-status/SENTINEL_STOP` → absent).

- [ ] **Step 3: Commit the chain**

```bash
git add two_jup/skidfix/flash_148_ddrcap2.sh
git commit -s -m "DDRCAP2 148-only flash chain with rails (readback, two-pass mode-1 gate, Tier-2 witness before rollback, no retry)

Claude-Session: https://claude.ai/code/session_019NZLGbxoaPRkDnKFMPiBrq"
```

- [ ] **Step 4: OPERATOR GO, then flash (rig-holding unit)**

Stop here and confirm with the operator that (a) the Tier-1 gate PASSED (§80), (b) the image is banked, (c) 148 is idle on the golden arm and 146 is untouched. Then:
```bash
cd two_jup && bash launch_rig_unit.sh ddrcap2-flash-$(date +%H%M%S) skidfix/flash_148_ddrcap2.sh <md5-12>
# monitor by reading skidfix/ddrcap2_flash_*.log every 60 s; do NOT intervene mid-flash; total ≈ 8-10 min
```
Expected: `FLASH_DDRCAP2_OK`. On `FLASH_DDRCAP2_ROLLED_BACK`, the campaign stops for the operator (no second attempt this session). Append §81 (flash result + the witness summary) to the session log and commit.

---

