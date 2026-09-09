### Task 5: Build the image on hdl-dev-2 and bank it

**Files:**
- Create: `jupiter_byte_ddrcap2_build/` (from `jupiter_byte_txmark_build/`), its `build_ddrcap.sh` (REMOTE_DIR renamed)
- Output: `boot_known_good/BOOT.BIN.148.ddrcap2.<md5-12>`, `boot_known_good/MD5SUMS` updated, README row

- [ ] **Step 1: Make the build tree and inject**

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem
rsync -a --exclude 'hdl_prj_jupiter_composite/vivado_ip_prj/vivado_prj.runs/' --exclude '*.log' --exclude '*.jou' \
      jupiter_byte_txmark_build/ jupiter_byte_ddrcap2_build/
sed -i "s|jupiter_byte_ddrcap_build|jupiter_byte_ddrcap2_build|g" jupiter_byte_ddrcap2_build/build_ddrcap.sh
grep -n "REMOTE_DIR" jupiter_byte_ddrcap2_build/build_ddrcap.sh | head -3
TXMARK=1 python3 two_jup/skidfix/ddrcap_inject.py jupiter_byte_ddrcap2_build | tail -2     # expect all 'already' + VERIFY_OK x2
python3 two_jup/skidfix/ddrcap2_inject.py jupiter_byte_ddrcap2_build | tail -12            # expect zips=2 zips_verified=2, exit 0
```
Expected: `DDRCAP2_INJECT ... missing=[] zips=2 zips_verified=2`. Anything else stops the task.

- [ ] **Step 2: Launch the build (from nemo) and watch it**

```bash
bash jupiter_byte_ddrcap2_build/build_ddrcap.sh | tee jupiter_byte_ddrcap2_build/launch.log
# The unit name is printed. Check every ~10 min (bounded): 
ssh hdl-dev-2 "tail -3 ~/qpsk-builds/jupiter_byte_ddrcap2_build/build_ddrcap_vivado.log; ls -la ~/qpsk-builds/jupiter_byte_ddrcap2_build/hdl_prj_jupiter_composite/vivado_ip_prj/boot/BOOT.BIN 2>/dev/null"
```
Expected after ~50 min: `BOOT.BIN` present, size 7,203,552; the vivado log ends without `ERROR`, timing met (`grep -i "all user specified timing constraints are met\|WNS" build_ddrcap_vivado.log`). A timing violation or synthesis error = report, do not flash.

- [ ] **Step 3: Fetch, verify, bank**

```bash
scp hdl-dev-2:~/qpsk-builds/jupiter_byte_ddrcap2_build/hdl_prj_jupiter_composite/vivado_ip_prj/boot/BOOT.BIN jupiter_byte_ddrcap2_build/hdl_prj_jupiter_composite/vivado_ip_prj/boot/BOOT.BIN
M=$(md5sum jupiter_byte_ddrcap2_build/hdl_prj_jupiter_composite/vivado_ip_prj/boot/BOOT.BIN | cut -c1-12)
cp jupiter_byte_ddrcap2_build/hdl_prj_jupiter_composite/vivado_ip_prj/boot/BOOT.BIN boot_known_good/BOOT.BIN.148.ddrcap2.$M
(cd boot_known_good && md5sum BOOT.BIN.148.ddrcap2.$M >> MD5SUMS && md5sum -c MD5SUMS | tail -2)
echo "| \`BOOT.BIN.148.ddrcap2.$M\` | \`$M\` | DDRCAP-v2: joint tOff/markers/sidecar record + sel12-15 (spec 2026-09-02). Built from txmark tree + ddrcap2_inject. NOT yet flashed. |" >> boot_known_good/README.md
git add boot_known_good/MD5SUMS boot_known_good/README.md jupiter_byte_ddrcap2_build/build_ddrcap.sh
git commit -s -m "DDRCAP2 image built and banked: BOOT.BIN.148.ddrcap2.$M

Claude-Session: https://claude.ai/code/session_019NZLGbxoaPRkDnKFMPiBrq"
```
(BOOT.BIN files are not committed; the bank directory holds them.)

---

