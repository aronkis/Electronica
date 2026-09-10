#!/bin/bash
# =============================================================================
# deploy_dtb.sh -- build/deploy the interrupt-driven-DMA system.dtb (workstream
# B) to ONE Jupiter, with the SAME safety envelope as deploy_image.sh. A bad
# /boot/system.dtb bricks boot exactly like a bad BOOT.BIN -- Jupiter has NO
# remote power, recovery is a physical SD reflash -- so the backup + working
# rollback here are LOAD-BEARING, not optional.
#
# SUBCOMMANDS
#   deploy_dtb.sh build [TX_SPI_CELL RX_SPI_CELL]
#         On the BUILD HOST (not a board): substitute the @..@ SPI-cell
#         placeholders in qpsk_byte_uio.dtso, dtc-compile it to .dtbo, and
#         fdtoverlay-merge it into the pristine base system.dtb, producing
#         system-qpsk.dtb. SPI cells come from wire_byte_irqs.tcl's
#         `BYTE_IRQ_MAP ... tx_spi_cell=<n> rx_spi_cell=<n>` line (= GIC SPI-32);
#         pass them as args or via TX_SPI_CELL/RX_SPI_CELL env. REFUSES to build
#         while any @..@ placeholder is unresolved.
#         Base dtb: scp it read-only from a board FIRST and keep a copy, e.g.
#           scp root@<ip>:/boot/system.dtb ./system.dtb.pristine   (see anyssh)
#         then:  BASE_DTB=./system.dtb.pristine deploy_dtb.sh build 110 111
#
#   deploy_dtb.sh check <merged-system.dtb>
#         Read-only validation of a merged dtb (no board): dtc round-trip parse,
#         assert the three qpsk_* nodes + the single 2 MB carve, refuse on any
#         residual placeholder. Same gate the deploy path runs before copying.
#
#   deploy_dtb.sh <ip> [merged-system.dtb]
#         Deploy to ONE board. With no dtb argument the BANKED dtb for that board is
#         used: images/system-qpsk.<last-octet-of-ip>.dtb.<md5> (exactly one
#         must match; 148 and 146 have different base dtbs). Validate, back up /boot/system.dtb (size-checked),
#         stage to /root and size-verify BEFORE overwriting /boot, install the
#         modprobe.d/modules-load.d files, reboot, wait for the board back, then
#         run the read-only post-reboot PASS/FAIL verify.
#
#   deploy_dtb.sh rollback <ip>
#         Restore /boot/system.dtb from the backup made by the last deploy,
#         reboot, wait for the board back.
#
# SAFETY (mirrors deploy_image.sh): backup at $SUFFIX overwritten every run --
# deploy the two boards ONE AT A TIME and confirm each healthy before the next,
# so you never lose your only known-good rollback. Staging goes to /root (the
# proven deploy_image.sh pattern; the brief mentioned /dev/shm -- deviated to
# match the working tool and because /root survives across the copy step).
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
KIT=$(cd "$D/.." && pwd)/modem/boot   # dtso + conf live here
BKG=$(cd "$D/.." && pwd)/images            # banked per-board qpsk dtbs
# banked_dtb <ip-or-board> -> path of images/system-qpsk.<board>.dtb.* (one match)
banked_dtb(){
  local b=${1##*.} m; m=$(ls "$BKG"/system-qpsk."$b".dtb.* 2>/dev/null)
  [ -n "$m" ] || { echo "FATAL: no banked dtb $BKG/system-qpsk.$b.dtb.* for board $b (pass an explicit dtb)" >&2; return 1; }
  [ "$(printf '%s\n' "$m" | wc -l)" -eq 1 ] || { echo "FATAL: several banked dtbs for board $b:" "$m" >&2; return 1; }
  echo "$m"
}
DTSO=$KIT/qpsk_byte_uio.dtso
MODPROBE_CONF=$KIT/uio-genirq.conf
SUFFIX=${SUFFIX:-.preqpsk}         # rollback backup: /boot/system.dtb$SUFFIX
PLACEHOLDERS='@TX_SPI_CELL@|@RX_SPI_CELL@'

scpput(){ SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no "$@" </dev/null 2>/dev/null; }

die(){ echo "FATAL: $*" >&2; exit 1; }

# --- shared read-only validation of a flat (merged) dtb --------------------
validate_dtb(){
  local dtb=$1
  [ -f "$dtb" ] || die "dtb not found: $dtb"
  local sz; sz=$(stat -c %s "$dtb" 2>/dev/null || echo 0)
  # a ZynqMP system.dtb is ~30-80 KB; guard against truncation / a stray BOOT.BIN
  [ "$sz" -gt 8000 ] && [ "$sz" -lt 1000000 ] || die "dtb size $sz out of sane range (8KB..1MB): $dtb"
  # must be a parseable FDT (round-trip through dtc)
  dtc -I dtb -O dts "$dtb" >/dev/null 2>&1 || die "dtb does not round-trip through dtc (corrupt?): $dtb"
  # no residual placeholders anywhere in the tree
  if dtc -I dtb -O dts "$dtb" 2>/dev/null | grep -Eq "$PLACEHOLDERS"; then
    die "dtb still contains @..@ SPI placeholders -- run 'build' with real SPI cells first"
  fi
  local dts; dts=$(dtc -I dtb -O dts "$dtb" 2>/dev/null)
  # the three qpsk UIO nodes
  local n
  for n in qpsk_tx_dma qpsk_rx_dma qpsk_byte_gpio; do
    echo "$dts" | grep -q "$n@" || die "merged dtb missing node $n"
  done
  # exactly one carve node, covering 0x7FE00000 / 0x200000 (2 MB)
  local cnt; cnt=$(echo "$dts" | grep -c "qpsk_byte_buf@")
  [ "$cnt" -eq 1 ] || die "expected exactly 1 qpsk_byte_buf node, found $cnt (overlap/stale carve)"
  echo "$dts" | grep -A3 "qpsk_byte_buf@" | grep -q "0x7fe00000 0x00 0x200000" \
    || die "carve reg is not the 2 MB @0x7FE00000 layout (got: $(echo "$dts" | grep -A3 qpsk_byte_buf@ | grep reg))"
  # the two interrupt-bearing nodes must resolve an interrupt-parent (inherited
  # from /axi_pl). fdtget on the node returns NOTFOUND (correct -- inherited),
  # so assert the inheritance SOURCE instead: /axi_pl interrupt-parent present.
  fdtget "$dtb" /axi_pl interrupt-parent >/dev/null 2>&1 \
    || die "/axi_pl has no interrupt-parent -- UIO IRQ nodes would have no GIC linkage"
  echo "  validate OK: 3 qpsk nodes, single 2MB carve, /axi_pl->gic inheritance intact, no placeholders (size=$sz)"
}

# --- build: substitute placeholders, compile overlay, merge into base ------
do_build(){
  local tx=${1:-${TX_SPI_CELL:-}} rx=${2:-${RX_SPI_CELL:-}}
  local base=${BASE_DTB:-$D/system.dtb.pristine}
  local out=${OUT_DTB:-$D/system-qpsk.dtb}
  [ -f "$DTSO" ]  || die "overlay source missing: $DTSO"
  [ -f "$base" ]  || die "base dtb missing: $base  (scp root@<ip>:/boot/system.dtb here first, keep a copy)"
  [ -n "$tx" ] && [ -n "$rx" ] || die "usage: deploy_dtb.sh build <TX_SPI_CELL> <RX_SPI_CELL>  (DT cell = GIC SPI - 32, from BYTE_IRQ_MAP)"
  echo "$tx$rx" | grep -Eq '^[0-9]+$' || die "SPI cells must be integers (got tx=$tx rx=$rx)"
  which dtc >/dev/null 2>&1        || die "dtc not found on build host"
  which fdtoverlay >/dev/null 2>&1 || die "fdtoverlay not found on build host"
  # intermediates go next to the OUTPUT (never into the repo/script dir)
  local odir; odir=$(dirname "$out")
  local sub=$odir/qpsk_byte_uio.sub.dtso dtbo=$odir/qpsk_byte_uio.dtbo
  sed -e "s/@TX_SPI_CELL@/$tx/g" -e "s/@RX_SPI_CELL@/$rx/g" "$DTSO" > "$sub"
  grep -Eq "$PLACEHOLDERS" "$sub" && die "placeholders still present after substitution (internal error)"
  echo "=== dtc compile overlay (SPI cells tx=$tx rx=$rx -> GIC SPI $((tx+32))/$((rx+32))) ==="
  # These warnings are EXPECTED and benign: 'Missing interrupt-parent' (nodes
  # inherit it from /axi_pl by design) and the fragment@1 reg_format/addr-size
  # warnings (dtc can't see the target reserved-memory 2/2 cell sizes when
  # compiling the overlay standalone; the merged result is verified correct).
  dtc -@ -I dts -O dtb -o "$dtbo" "$sub" || die "overlay failed to compile"
  echo "=== fdtoverlay merge into $(basename "$base") -> $(basename "$out") ==="
  cp "$base" "$out"
  fdtoverlay -i "$base" -o "$out" "$dtbo" || die "fdtoverlay merge failed"
  validate_dtb "$out"
  echo "BUILD_OK: $out  (deploy with: deploy_dtb.sh <ip> $out)"
}

# --- deploy: safety envelope cloned from deploy_image.sh -------------------
do_deploy(){
  local ip=$1 dtb=$2
  echo "=== DEPLOY DTB -> $ip  $(date -Is) ==="
  validate_dtb "$dtb"
  local sz md5; sz=$(stat -c %s "$dtb"); md5=$(md5sum "$dtb" | cut -c1-12)
  echo "new system.dtb: size=$sz md5=$md5  (path=$dtb)"
  $W "$ip" 'echo up' 2>/dev/null | grep -q up || die "$ip unreachable via anyssh.sh"
  local free; free=$($W "$ip" "df -k /boot | awk 'NR==2{print \$4}'" 2>/dev/null || echo 0)
  [ "${free:-0}" -gt 1000 ] || die "/boot free ${free}KB too small for backup"
  echo "  /boot free: ${free}KB"
  # back up current /boot/system.dtb (only if it is a sane FDT, magic d00dfeed)
  echo "  backup: $($W "$ip" "CB=\$(stat -c %s /boot/system.dtb 2>/dev/null||echo 0); MG=\$(head -c4 /boot/system.dtb 2>/dev/null|od -An -tx1|tr -d ' '); if [ \"\$CB\" -gt 8000 ] && [ \"\$MG\" = d00dfeed ]; then cp -f /boot/system.dtb /boot/system.dtb$SUFFIX && sync && echo \"OK current=\$CB -> /boot/system.dtb$SUFFIX\"; else echo \"REFUSE current size=\$CB magic=\$MG\"; fi" 2>/dev/null)"
  $W "$ip" "test -f /boot/system.dtb$SUFFIX" 2>/dev/null || die "backup not present -- aborting before overwrite"
  # stage new dtb to /root, verify size + FDT magic, THEN overwrite /boot
  scpput "$dtb" root@"$ip":/root/system.dtb.staged
  local fl; fl=$($W "$ip" "NB=\$(stat -c %s /root/system.dtb.staged 2>/dev/null||echo 0); MG=\$(head -c4 /root/system.dtb.staged 2>/dev/null|od -An -tx1|tr -d ' '); if [ \"\$NB\" -gt 8000 ] && [ \"\$MG\" = d00dfeed ]; then cp -f /root/system.dtb.staged /boot/system.dtb && sync && echo \"FLASHED size=\$NB md5=\$(md5sum /boot/system.dtb|cut -c1-12)\"; else echo \"ABORT staged size=\$NB magic=\$MG\"; fi" 2>/dev/null)
  echo "  flash: $fl"
  echo "$fl" | grep -q FLASHED || die "flash did not complete -- /boot untouched, rollback with deploy_dtb.sh rollback $ip"
  # install the modprobe.d + modules-load.d autoload config (best-effort)
  install_modconf "$ip"
  # reboot and wait for the board back (bounded), mirroring deploy_image.sh
  echo "  rebooting $ip ..."; $W "$ip" 'sync; (sleep 1; reboot) &' 2>/dev/null
  until ! ping -c1 -W1 "$ip" >/dev/null 2>&1; do sleep 2; done
  local t=0; until ping -c1 -W2 "$ip" >/dev/null 2>&1; do sleep 3; t=$((t+3)); [ "$t" -gt 180 ] && { echo "WARN: $ip not back after 180s -- check console"; break; }; done
  sleep 20
  echo "=== $ip back up: $($W "$ip" 'head -c4 /boot/system.dtb|od -An -tx1|tr -d " "' 2>/dev/null) (want d00dfeed) ==="
  verify_board "$ip"
}

install_modconf(){
  local ip=$1
  [ -f "$MODPROBE_CONF" ] || { echo "  WARN: $MODPROBE_CONF missing -- skipping modconf install"; return; }
  scpput "$MODPROBE_CONF" root@"$ip":/etc/modprobe.d/uio-genirq.conf
  $W "$ip" 'mkdir -p /etc/modules-load.d && printf "uio_pdrv_genirq\n" > /etc/modules-load.d/uio-genirq.conf && echo "  modconf installed (modprobe.d + modules-load.d)"' 2>/dev/null
  # honest heads-up: the module may not exist for the running kernel (recon).
  $W "$ip" 'if [ ! -d /lib/modules/$(uname -r) ]; then echo "  NOTE: /lib/modules/$(uname -r) absent -- uio_pdrv_genirq CANNOT load until the kernel ships it built-in (=y) or installs the module tree"; fi' 2>/dev/null
}

# --- read-only post-reboot verification ------------------------------------
verify_board(){
  local ip=$1 pass=1
  echo "=== POST-REBOOT VERIFY $ip (read-only) ==="
  # 1. /sys/class/uio has the three qpsk nodes. uio_pdrv_genirq names them from
  #    the DT node: EITHER bare ("qpsk_tx_dma") OR with the @unit-address
  #    ("qpsk_tx_dma@9d100000") -- kernel 6.12.77 uses the '@' form. Match both.
  #    (The old "9d300000 claimed in /proc/iomem" check was DROPPED: generic-uio
  #    does NOT request_mem_region for its maps, so the region never appears in
  #    /proc/iomem even when the device is correctly bound -- it was a guaranteed
  #    false negative. UIO-name presence + the SPI IRQ lines below are the real
  #    positive-presence signals.)
  local names; names=$($W "$ip" 'for u in /sys/class/uio/uio*; do [ -e "$u/name" ] && cat "$u/name"; done' 2>/dev/null)
  local n
  for n in qpsk_tx_dma qpsk_rx_dma qpsk_byte_gpio; do
    if echo "$names" | grep -qE "^$n(@|\$)"; then echo "  PASS uio: $n present"; else echo "  FAIL uio: $n missing (uio_pdrv_genirq bound?)"; pass=0; fi
  done
  # 3. the two new SPIs / qpsk irqs in /proc/interrupts
  if $W "$ip" 'grep -Eqi "qpsk_(tx|rx)_dma" /proc/interrupts' 2>/dev/null; then echo "  PASS irq: qpsk dma interrupts registered"; else echo "  FAIL irq: no qpsk dma lines in /proc/interrupts"; pass=0; fi
  echo "=== VERIFY $ip: $([ $pass -eq 1 ] && echo PASS || echo FAIL) ==="
  [ $pass -eq 1 ]
}

# --- rollback --------------------------------------------------------------
do_rollback(){
  local ip=$1
  echo "=== ROLLBACK DTB on $ip  $(date -Is) ==="
  $W "$ip" 'echo up' 2>/dev/null | grep -q up || die "$ip unreachable"
  local r; r=$($W "$ip" "if [ -f /boot/system.dtb$SUFFIX ]; then MG=\$(head -c4 /boot/system.dtb$SUFFIX|od -An -tx1|tr -d ' '); if [ \"\$MG\" = d00dfeed ]; then cp -f /boot/system.dtb$SUFFIX /boot/system.dtb && sync && echo RESTORED; else echo \"REFUSE backup magic=\$MG\"; fi; else echo NO_BACKUP; fi" 2>/dev/null)
  echo "  rollback: $r"
  echo "$r" | grep -q RESTORED || die "rollback did not restore (backup /boot/system.dtb$SUFFIX missing or corrupt)"
  echo "  rebooting $ip ..."; $W "$ip" 'sync; (sleep 1; reboot) &' 2>/dev/null
  until ! ping -c1 -W1 "$ip" >/dev/null 2>&1; do sleep 2; done
  local t=0; until ping -c1 -W2 "$ip" >/dev/null 2>&1; do sleep 3; t=$((t+3)); [ "$t" -gt 180 ] && { echo "WARN: $ip not back after 180s"; break; }; done
  echo "=== $ip rolled back ==="
}

# --- dispatch --------------------------------------------------------------
usage(){ sed -n '2,45p' "$0"; exit 2; }
[ $# -ge 1 ] || usage
case "$1" in
  build)    shift; do_build "$@" ;;
  check)    shift; [ $# -ge 1 ] || die "usage: deploy_dtb.sh check <merged.dtb | board>"
            F=$1; [ -f "$F" ] || F=$(banked_dtb "$F") || exit 1; validate_dtb "$F"; echo "CHECK_OK: $F" ;;
  rollback) shift; [ $# -ge 1 ] || die "usage: deploy_dtb.sh rollback <ip>"; do_rollback "$1" ;;
  -h|--help|help) usage ;;
  *)
    [ $# -ge 1 ] || die "usage: deploy_dtb.sh <ip> [merged-system.dtb]  |  build|check|rollback (see --help)"
    F=${2:-}; [ -n "$F" ] || F=$(banked_dtb "$1") || exit 1
    echo "=== dtb for $1: $F ==="
    do_deploy "$1" "$F" ;;
esac
