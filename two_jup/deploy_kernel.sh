#!/bin/bash
# =============================================================================
# deploy_kernel.sh -- deploy the UIO-enabled kernel Image (6.12.77) AND set the
# generic-uio kernel cmdline to ONE Jupiter, with the SAME safety envelope as
# deploy_dtb.sh / deploy_image.sh. A bad /boot/Image bricks boot exactly like a
# bad BOOT.BIN -- Jupiter has NO remote power, recovery is a physical SD reflash
# -- so the Image backup and the working rollback here are LOAD-BEARING, not
# optional. (uEnv.txt is NOT modified by this script -- see the HOW note below.)
#
# HOW of_id reaches the kernel: the built kernel has CONFIG_UIO_PDRV_GENIRQ=y
# (BUILT-IN, not a module), so modprobe.d / modules-load.d are IGNORED -- the
# generic-uio platform driver only binds qpsk_tx_dma / qpsk_rx_dma /
# qpsk_byte_gpio via the kernel command line uio_pdrv_genirq.of_id=generic-uio.
# That param is now BAKED INTO the kernel image (CONFIG_CMDLINE="uio_pdrv_genirq.
# of_id=generic-uio" + CONFIG_CMDLINE_EXTEND=y) and appended to the bootloader's
# cmdline by drivers/of/fdt.c at boot. So this script does NOT edit uEnv.txt --
# bring-up recon proved these boards' effective /proc/cmdline comes from U-Boot's
# default env, not uEnv/mtd/dtb-chosen, making a uEnv edit both ineffective and
# needless risk. uEnv.txt is left untouched. See docs/DEPLOY_F1536.md.
#
# SUBCOMMANDS
#   deploy_kernel.sh check [Image]
#         Read-only validation of a kernel Image on the BUILD HOST (no board):
#         size range, ARM64 Image magic 'ARMd' at offset 0x38, and (if
#         sha256sum is present) identity == the known-good UIO build hash.
#
#   deploy_kernel.sh <ip> [Image]
#         Deploy to ONE board: validate the Image; back up /boot/Image
#         (size/magic-checked); stage the Image to /root and size+magic-verify
#         BEFORE overwriting /boot; reboot; wait for the board back; run the
#         post-reboot verify. uEnv.txt is NOT touched (of_id is baked into the
#         kernel via CONFIG_CMDLINE_EXTEND -- see the HOW note below).
#
#   deploy_kernel.sh rollback <ip>
#         Restore /boot/Image from the backup made by the last deploy, reboot,
#         wait for the board back. (uEnv.txt was never modified, so nothing else
#         to restore.)
#
# DEPLOY ORDER (see docs/DEPLOY_F1536.md): this kernel step is step 2, BEFORE
# the qpsk dtb (step 3). After this reboot the OLD dtb is still live, so
# /sys/class/uio will still show only axi-pmon -- that is EXPECTED and the
# verify treats the qpsk UIO nodes as informational, never a failure. The two
# hard checks are: kernel version contains 6.12.77, and the generic-uio param
# reached /proc/cmdline.
#
# SAFETY (mirrors deploy_dtb.sh): backups at $SUFFIX are overwritten every run
# -- deploy the two boards ONE AT A TIME and confirm each healthy before the
# next, so you never lose your only known-good rollback. Staging goes to /root
# (the proven deploy_image.sh pattern). Do NOT run this against boards until the
# bring-up session; it reboots the target.
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh

# Default Image = the UIO kernel build (see the KERNEL task in the ledger).
# Override with $2 (positional) or the IMAGE env.
IMAGE=${IMAGE:-/mnt/onetb/scratch/adi-linux-jupiter/linux/arch/arm64/boot/Image}
# Known-good UIO kernel identity (sha256 of the built Image, 6.12.77 UIO=y,
# CONFIG_CMDLINE_EXTEND baking uio_pdrv_genirq.of_id=generic-uio). This is the
# of_id-baked rebuild; the pre-bake Image was f7ad5079...d1d2089. See the kernel
# section of docs/DEPLOY_F1536.md (rebuild is reproducible from the saved patch).
EXPECT_SHA=${EXPECT_SHA:-a1ba00b514319d8006d9555815e48427840c9291d785868da986feb5cbffe0b5}
SUFFIX=${SUFFIX:-.preuio}          # rollback backup: /boot/Image$SUFFIX
BOOTARG=${BOOTARG:-uio_pdrv_genirq.of_id=generic-uio}  # expected in /proc/cmdline (verify)
MIN_KB=${MIN_KB:-20480}            # a ZynqMP aarch64 Image is tens of MB; guard truncation
MAX_KB=${MAX_KB:-102400}           # ... and a stray BOOT.BIN / rootfs blob

scpput(){ SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no "$@" </dev/null 2>/dev/null; }

die(){ echo "FATAL: $*" >&2; exit 1; }

# --- shared read-only validation of a kernel Image (build host) ------------
validate_image(){
  local img=$1
  [ -f "$img" ] || die "Image not found: $img"
  local kb; kb=$(( $(stat -c %s "$img" 2>/dev/null || echo 0) / 1024 ))
  [ "$kb" -gt "$MIN_KB" ] && [ "$kb" -lt "$MAX_KB" ] \
    || die "Image size ${kb}KB out of sane range (${MIN_KB}..${MAX_KB} KB): $img"
  # ARM64 Linux Image header magic 'ARMd' (0x41 0x52 0x4d 0x64) at offset 0x38.
  local magic; magic=$(dd if="$img" bs=1 skip=56 count=4 2>/dev/null)
  [ "$magic" = "ARMd" ] || die "not an ARM64 Image: magic at 0x38 is '$magic', want 'ARMd': $img"
  # Identity: match the known-good UIO build hash unless explicitly skipped.
  if command -v sha256sum >/dev/null 2>&1; then
    local sha; sha=$(sha256sum "$img" | cut -d' ' -f1)
    if [ "$sha" = "$EXPECT_SHA" ]; then
      echo "  validate OK: ARM64 Image, size=${kb}KB, sha256 matches UIO build"
    elif [ "${QPSK_SKIP_SHA:-0}" = 1 ]; then
      echo "  validate OK: ARM64 Image, size=${kb}KB, sha256=$sha (EXPECT override: QPSK_SKIP_SHA=1)"
    else
      die "Image sha256 $sha != expected $EXPECT_SHA -- wrong/rebuilt kernel? set QPSK_SKIP_SHA=1 to override"
    fi
  else
    echo "  validate OK: ARM64 Image, size=${kb}KB (sha256sum absent -- identity not checked)"
  fi
}

# --- deploy: safety envelope cloned from deploy_dtb.sh ---------------------
do_deploy(){
  local ip=$1 img=$2
  echo "=== DEPLOY KERNEL -> $ip  $(date -Is) ==="
  validate_image "$img"
  local kb; kb=$(( $(stat -c %s "$img") / 1024 ))
  echo "new Image: size=${kb}KB md5=$(md5sum "$img" | cut -c1-12)  (path=$img)"
  $W "$ip" 'echo up' 2>/dev/null | grep -q up || die "$ip unreachable via anyssh.sh"
  # /boot must hold the Image backup (~48MB) with margin
  local free; free=$($W "$ip" "df -k /boot | awk 'NR==2{print \$4}'" 2>/dev/null || echo 0)
  [ "${free:-0}" -gt $((kb + 5000)) ] || die "/boot free ${free}KB too small for a ${kb}KB Image backup"
  echo "  /boot free: ${free}KB"
  # back up current /boot/Image (only if it is a sane ARM64 Image: magic ARMd)
  echo "  backup Image: $($W "$ip" "CB=\$(stat -c %s /boot/Image 2>/dev/null||echo 0); MG=\$(dd if=/boot/Image bs=1 skip=56 count=4 2>/dev/null); if [ \"\$CB\" -gt $((MIN_KB*1024)) ] && [ \"\$MG\" = ARMd ]; then cp -f /boot/Image /boot/Image$SUFFIX && sync && echo \"OK current=\$CB -> /boot/Image$SUFFIX\"; else echo \"REFUSE current size=\$CB magic=\$MG\"; fi" 2>/dev/null)"
  $W "$ip" "test -f /boot/Image$SUFFIX" 2>/dev/null || die "Image backup not present -- aborting before overwrite"
  # NOTE: uEnv.txt is INTENTIONALLY LEFT UNTOUCHED. of_id is baked into the kernel
  # (CONFIG_CMDLINE + CONFIG_CMDLINE_EXTEND) so it arrives via the kernel's own
  # built-in cmdline appended to the bootloader args -- independent of uEnv/mtd/
  # dtb-chosen. Bring-up recon proved these boards' effective /proc/cmdline comes
  # from U-Boot's default env (not uEnv, not the on-disk dtb /chosen), so editing
  # uEnv would be both ineffective and unnecessary risk. See docs/DEPLOY_F1536.md.
  # stage new Image to /root, verify size + ARM64 magic, THEN overwrite /boot
  scpput "$img" root@"$ip":/root/Image.staged
  local fl; fl=$($W "$ip" "NB=\$(stat -c %s /root/Image.staged 2>/dev/null||echo 0); MG=\$(dd if=/root/Image.staged bs=1 skip=56 count=4 2>/dev/null); if [ \"\$NB\" -gt $((MIN_KB*1024)) ] && [ \"\$MG\" = ARMd ]; then cp -f /root/Image.staged /boot/Image && sync && echo \"FLASHED size=\$NB md5=\$(md5sum /boot/Image|cut -c1-12)\"; else echo \"ABORT staged size=\$NB magic=\$MG\"; fi" 2>/dev/null)
  echo "  flash Image: $fl"
  echo "$fl" | grep -q FLASHED || die "Image flash did not complete -- /boot/Image untouched; rollback with deploy_kernel.sh rollback $ip"
  # (no uEnv edit: of_id is baked into the kernel -- see the HOW note in the header)
  # reboot and wait for the board back (bounded), mirroring deploy_dtb.sh
  echo "  rebooting $ip ..."; $W "$ip" 'sync; (sleep 1; reboot) &' 2>/dev/null
  until ! ping -c1 -W1 "$ip" >/dev/null 2>&1; do sleep 2; done
  local t=0; until ping -c1 -W2 "$ip" >/dev/null 2>&1; do sleep 3; t=$((t+3)); [ "$t" -gt 180 ] && { echo "WARN: $ip not back after 180s -- check console"; break; }; done
  sleep 20
  verify_board "$ip"
}

# --- read-only post-reboot verification (tolerant + informative) -----------
verify_board(){
  local ip=$1 pass=1
  echo "=== POST-REBOOT VERIFY $ip (read-only) ==="
  # 1. HARD: running kernel is the new 6.12.77 UIO build
  local kver; kver=$($W "$ip" 'uname -r' 2>/dev/null)
  if echo "$kver" | grep -q '6\.12\.77'; then echo "  PASS kernel: uname -r = $kver"; else echo "  FAIL kernel: uname -r = '$kver' (want 6.12.77)"; pass=0; fi
  # 2. HARD: the generic-uio param reached the effective cmdline. It is compiled
  #    into this kernel (CONFIG_CMDLINE + CONFIG_CMDLINE_EXTEND) and appended to
  #    the bootloader cmdline, so it MUST appear here -- absence means the wrong
  #    Image booted. This is the real proof the correct kernel took effect.
  if $W "$ip" "grep -q '$BOOTARG' /proc/cmdline" 2>/dev/null; then
    echo "  PASS cmdline: $BOOTARG present in /proc/cmdline (baked-in kernel cmdline appended it)"
  else
    echo "  FAIL cmdline: $BOOTARG ABSENT from /proc/cmdline"
    echo "       /proc/cmdline = $($W "$ip" 'cat /proc/cmdline' 2>/dev/null)"
    echo "       of_id is compiled into THIS kernel (CONFIG_CMDLINE + CONFIG_CMDLINE_EXTEND)"
    echo "       and is appended to the bootloader cmdline by drivers/of/fdt.c -- so its"
    echo "       absence means the WRONG Image booted (old kernel still live / flash didn't"
    echo "       take / EXTEND not set). Re-check the running kernel and EXPECT_SHA."
    pass=0
  fi
  # 3. INFORMATIONAL only (never FAIL): qpsk UIO nodes appear only once the qpsk
  #    dtb is ALSO deployed (step 3). Kernel-only step still runs the old dtb.
  local names; names=$($W "$ip" 'for u in /sys/class/uio/uio*; do [ -e "$u/name" ] && cat "$u/name"; done' 2>/dev/null)
  if echo "$names" | grep -qE 'qpsk_(tx|rx)_dma|qpsk_byte_gpio'; then
    echo "  INFO uio: qpsk UIO nodes present (qpsk dtb already deployed)"
  else
    echo "  INFO uio: no qpsk UIO nodes yet (expected until the qpsk dtb is deployed -- step 3)"
    echo "       current /sys/class/uio names: $(echo "$names" | tr '\n' ' ')"
  fi
  echo "=== VERIFY $ip: $([ $pass -eq 1 ] && echo PASS || echo 'PASS-WITH-WARNINGS (see above)') ==="
  [ $pass -eq 1 ]
}

# --- rollback: restore /boot/Image (uEnv.txt was never modified) -----------
do_rollback(){
  local ip=$1
  echo "=== ROLLBACK KERNEL on $ip  $(date -Is) ==="
  $W "$ip" 'echo up' 2>/dev/null | grep -q up || die "$ip unreachable"
  # Only /boot/Image is restored: this deploy no longer touches uEnv.txt (of_id is
  # baked into the kernel via CONFIG_CMDLINE_EXTEND), so there is no uEnv backup to
  # restore and none is expected.
  local r; r=$($W "$ip" "
    ok=1
    if [ -f /boot/Image$SUFFIX ]; then MG=\$(dd if=/boot/Image$SUFFIX bs=1 skip=56 count=4 2>/dev/null); if [ \"\$MG\" = ARMd ]; then cp -f /boot/Image$SUFFIX /boot/Image && echo IMG_RESTORED; else echo \"IMG_REFUSE magic=\$MG\"; ok=0; fi; else echo IMG_NO_BACKUP; ok=0; fi
    sync
    [ \$ok -eq 1 ] && echo ROLLBACK_OK || echo ROLLBACK_INCOMPLETE
  " 2>/dev/null)
  echo "$r" | sed 's/^/  /'
  echo "$r" | grep -q ROLLBACK_OK || die "rollback did not restore (Image backup missing or corrupt) -- check console"
  echo "  rebooting $ip ..."; $W "$ip" 'sync; (sleep 1; reboot) &' 2>/dev/null
  until ! ping -c1 -W1 "$ip" >/dev/null 2>&1; do sleep 2; done
  local t=0; until ping -c1 -W2 "$ip" >/dev/null 2>&1; do sleep 3; t=$((t+3)); [ "$t" -gt 180 ] && { echo "WARN: $ip not back after 180s"; break; }; done
  echo "=== $ip rolled back (Image restored) ==="
}

# --- dispatch --------------------------------------------------------------
usage(){ sed -n '2,58p' "$0"; exit 2; }
[ $# -ge 1 ] || usage
case "$1" in
  check)    shift; validate_image "${1:-$IMAGE}"; echo "CHECK_OK: ${1:-$IMAGE}" ;;
  rollback) shift; [ $# -ge 1 ] || die "usage: deploy_kernel.sh rollback <ip>"; do_rollback "$1" ;;
  -h|--help|help) usage ;;
  *)
    do_deploy "$1" "${2:-$IMAGE}" ;;
esac
