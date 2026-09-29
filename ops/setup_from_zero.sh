#!/bin/bash
# =============================================================================
# setup_from_zero.sh -- ONE entry point for taking two stock Jupiters to a
# running link, in the order the individual ops/ scripts have to be run in:
#
#     step0     deploy_kernel.sh + deploy_dtb.sh   (UIO kernel + qpsk dtb)
#     deploy    deploy_image.sh <ip> A|B           (modem BOOT.BIN, per role)
#     provision provision.sh <ip>                  (host app, profiles, watchdog)
#     bringup   bringup_r2r3.sh r3                 (loads profiles, ARMS BOTH RADIOS)
#     test      test.sh ber -d 90                  (two-board FDD acceptance)
#
# It drives those scripts, it does not reimplement them: every safety envelope
# (size checks, /boot backup, one-board-at-a-time) still lives in the script
# that owns it. What this adds is (a) a single probe of both boards, (b) the
# precondition between each pair of stages, asserted instead of assumed, and
# (c) a default mode that executes NOTHING.
#
#   ./setup_from_zero.sh                      # PLAN: probe both boards read-only,
#                                             #   print exactly what would run. Default.
#   ./setup_from_zero.sh run --yes            # execute step0..provision
#   ./setup_from_zero.sh run --yes --to test  # ...through bring-up and acceptance
#   ./setup_from_zero.sh run --yes --from provision --to provision
#   A_IP=10.0.0.170 B_IP=10.0.0.171 ./setup_from_zero.sh
#
# SAFETY. Two stages change RF state -- `bringup` loads an ADRV9002 profile and
# arms both radios, `test` keys the link. They are OUTSIDE the default --to and
# cannot run unless you name them, in addition to `run --yes`. The plan mode is
# read-only: it opens one ssh per board and reads uname, /sys/class/uio, and a
# few md5s. It never writes a register, never restarts a daemon.
#
# Re-running is not free: see README.md "Quick start". After a reboot you want
# `bringup_r2r3.sh r3` alone, not this script.
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$D/.." && pwd)
BKG=$ROOT/images
# bounded board calls, same envelope as provision.sh / deploy_image.sh
wssh(){ timeout "${SSH_T:-60}" "$D/anyssh.sh" "$@"; local rc=$?; [ $rc -eq 124 ] && echo "  [TIMEOUT] anyssh $1 exceeded ${SSH_T:-60}s" >&2; return $rc; }
W=wssh

A_IP=${A_IP:-10.0.0.148}
B_IP=${B_IP:-10.0.0.146}
KVER=${KVER:-6.12.77}
KIMG=${KIMG:-$BKG/Image.6.12.77-uio.a1ba00b51431}
RUNG=${RUNG:-r3}

STAGES="step0 deploy provision bringup test"
MODE=plan; YES=0; FROM=step0; TO=provision
while [ $# -gt 0 ]; do
  case "$1" in
    plan|run) MODE=$1 ;;
    --yes)    YES=1 ;;
    --from)   shift; FROM=${1:-} ;;
    --to)     shift; TO=${1:-} ;;
    -h|--help) sed -n '2,36p' "$0"; exit 2 ;;
    *) echo "FATAL: unknown argument '$1' (see --help)"; exit 2 ;;
  esac; shift
done
idx(){ local i=0 s; for s in $STAGES; do [ "$s" = "$1" ] && { echo $i; return 0; }; i=$((i+1)); done
       echo "FATAL: unknown stage '$1' (one of: $STAGES)" >&2; return 1; }
FI=$(idx "$FROM") || exit 2
TI=$(idx "$TO")   || exit 2
[ "$FI" -le "$TI" ] || { echo "FATAL: --from $FROM is after --to $TO"; exit 2; }
want(){ local i; i=$(idx "$1") || return 1; [ "$i" -ge "$FI" ] && [ "$i" -le "$TI" ]; }

echo "=== SETUP FROM ZERO  A=$A_IP  B=$B_IP  rung=$RUNG  $(date -Is) ==="
echo "    mode=$MODE  stages=$FROM..$TO"
[ "$MODE" = run ] && [ "$YES" != 1 ] && {
  echo "REFUSED: 'run' needs --yes as well. Re-read the plan first:  $0"; exit 2; }
if [ "$MODE" = run ] && { want bringup || want test; }; then
  echo "    [RF] this range includes '$(want test && echo test || echo bringup)': radios WILL be armed."
fi

# ---------------------------------------------------------------- probe ----
# One ssh per board, read-only. Everything the preconditions below need.
probe(){ # $1=ip -> sets P_up P_uname P_uio P_boot P_tun P_prof P_wd P_wdconf
  P_up=0 P_uname=- P_uio=0 P_boot=- P_tun=0 P_prof=0 P_wd=0 P_wdconf=none
  local out k v
  out=$($W "$1" '
    echo up=1
    echo uname=$(uname -r)
    echo uio=$(cat /sys/class/uio/*/name 2>/dev/null | grep -c "^qpsk_")
    echo boot=$(md5sum /boot/BOOT.BIN 2>/dev/null | cut -d" " -f1)
    echo tun=$([ -x /root/host_app_k5/qpsk_tun ] && echo 1 || echo 0)
    echo prof=$(ls /root/lvds_61p44_fdd_jupiter.bin /root/lvds_61p44_fdd_jupiter.json 2>/dev/null | wc -l)
    echo wd=$([ -x /root/lock_watchdog.sh ] && echo 1 || echo 0)
    echo wdconf=$([ -r /root/watchdog.conf ] && md5sum /root/watchdog.conf | cut -d" " -f1 || echo none)
  ' 2>/dev/null)
  while IFS='=' read -r k v; do case "$k" in
    up) P_up=$v;; uname) P_uname=$v;; uio) P_uio=$v;; boot) P_boot=$v;;
    tun) P_tun=$v;; prof) P_prof=$v;; wd) P_wd=$v;; wdconf) P_wdconf=$v;;
  esac; done <<EOF
$out
EOF
}
role_md5(){ grep -E "^$1 " "$BKG/CURRENT.txt" 2>/dev/null | head -1 | awk '{print $3}'; }
dtb_for(){ ls "$BKG"/system-qpsk."${1##*.}".dtb.* 2>/dev/null | head -1; }

ok(){ printf '  [ ok ] %s\n' "$1"; }
no(){ printf '  [TODO] %s\n' "$1"; }
bad(){ printf '  [FAIL] %s\n' "$1"; }

report(){ # $1=ip $2=role
  local want_md5 dtb; want_md5=$(role_md5 "$2"); dtb=$(dtb_for "$1")
  echo "-- $2 @ $1 --"
  [ "$P_up" = 1 ] || { bad "unreachable via anyssh.sh -- nothing else was probed"; return 1; }
  [ "$P_uname" = "$KVER" ] && ok "kernel $P_uname" || no "kernel is $P_uname, want $KVER  (step0: deploy_kernel.sh)"
  [ "${P_uio:-0}" -ge 3 ] && ok "qpsk UIO nodes $P_uio/3" || no "qpsk UIO nodes ${P_uio:-0}/3  (step0: deploy_dtb.sh $(basename "${dtb:-<missing in images/>}"))"
  if [ -z "$want_md5" ]; then bad "no role $2 line in images/CURRENT.txt"
  elif [ "$P_boot" = "$want_md5" ]; then ok "BOOT.BIN $P_boot matches CURRENT.txt role $2"
  else no "BOOT.BIN is $P_boot, CURRENT.txt role $2 wants $want_md5  (deploy)"; fi
  [ "$P_tun" = 1 ] && ok "/root/host_app_k5/qpsk_tun present" || no "qpsk_tun not built  (provision)"
  [ "${P_prof:-0}" -ge 2 ] && ok "rung-r3 profile pair present" || no "profile $RUNG missing  (provision)"
  [ "$P_wd" = 1 ] && ok "lock_watchdog.sh present" || no "lock_watchdog.sh missing  (provision)"
  if [ "$P_wdconf" = none ]; then
    [ -f "$D/watchdog.conf.${1##*.}" ] && no "no /root/watchdog.conf  (provision installs ops/watchdog.conf.${1##*.})" \
                                       || ok "no /root/watchdog.conf, and no template for this board -- built-in defaults"
  else
    ok "watchdog.conf $P_wdconf"
  fi
}

echo; echo "--- probing both boards (read-only) ---"
probe "$A_IP"; A_up=$P_up; report "$A_IP" A; A_uio=$P_uio; A_un=$P_uname; A_boot=$P_boot; A_tun=$P_tun
echo
probe "$B_IP"; B_up=$P_up; report "$B_IP" B; B_uio=$P_uio; B_un=$P_uname; B_boot=$P_boot; B_tun=$P_tun

# ------------------------------------------------------------------ images ----
# The kernel Image and the two BOOT.BINs are large and a given checkout may or
# may not carry them. Say so here, plainly, instead of failing two stages later
# inside deploy_kernel.sh / deploy_image.sh. Everything from `provision` onward
# needs NONE of them, so a clone without images is still fully usable -- it just
# cannot reflash a board.
role_file(){ grep -E "^$1 " "$BKG/CURRENT.txt" 2>/dev/null | head -1 | awk '{print $2}'; }
HAVE_K=0; { [ -f "$KIMG" ] || [ -f "$KIMG.gz" ]; } && HAVE_K=1
HAVE_IMG=1
echo; echo "--- images/ ---"
if [ "$HAVE_K" = 1 ]; then echo "  [ ok ] kernel   $(basename "$KIMG").gz"
else echo "  [ -- ] kernel   $(basename "$KIMG").gz absent -- step0 unavailable"; fi
for r in A B; do
  rf=$(role_file "$r")
  if [ -z "$rf" ]; then echo "  [FAIL] role $r  no line in images/CURRENT.txt"; HAVE_IMG=0
  elif [ -f "$BKG/$rf" ]; then echo "  [ ok ] role $r   $rf"
  else echo "  [ -- ] role $r   $rf absent -- deploy unavailable"; HAVE_IMG=0; fi
done
for ip in "$A_IP" "$B_IP"; do
  [ -n "$(dtb_for "$ip")" ] && echo "  [ ok ] dtb ${ip##*.}   $(basename "$(dtb_for "$ip")")" \
                            || echo "  [ -- ] dtb ${ip##*.}   system-qpsk.${ip##*.}.dtb.* absent -- step0 unavailable"
done
[ "$HAVE_K" = 1 ] && [ "$HAVE_IMG" = 1 ] || \
  echo "  Missing artifacts are fetched separately (see images/README.md); run --from provision to skip them."

# Only unpack the 47 MB kernel Image if a board actually needs flashing.
NEEDK=0; [ "$A_un" = "$KVER" ] && [ "$B_un" = "$KVER" ] || NEEDK=1

# -------------------------------------------------------------- the plan ----
echo; echo "--- plan ($FROM..$TO) ---"
plan_line(){ printf '  %s\n' "$1"; }
if want step0; then
  echo " step0:"
  [ -f "$KIMG" ] || [ "$NEEDK" = 0 ] || plan_line "cd $BKG && gunzip -kf $(basename "$KIMG").gz     # the raw Image is untracked (47 MB)"
  for pair in "A_IP $A_un $A_uio" "B_IP $B_un $B_uio"; do
    set -- $pair; eval ip=\$$1; un=$2; ui=$3
    if [ "$un" = "$KVER" ] && [ "${ui:-0}" -ge 3 ]; then plan_line "$ip: already $KVER + $ui UIO nodes -- SKIP"
    else
      [ "$un" = "$KVER" ] || plan_line "./deploy_kernel.sh $ip $KIMG   # reboots"
      d=$(dtb_for "$ip")
      [ -n "$d" ] && plan_line "./deploy_dtb.sh    $ip $d   # reboots" \
                  || plan_line "(cannot: no images/system-qpsk.${ip##*.}.dtb.* for $ip)"
    fi
  done
fi
want deploy    && { echo " deploy:";    for r in "A $A_IP $A_boot" "B $B_IP $B_boot"; do set -- $r
                      [ "$3" = "$(role_md5 "$1")" ] && plan_line "$2: BOOT.BIN already role $1 -- SKIP" \
                                                    || plan_line "./deploy_image.sh $2 $1   # backs up /boot, reboots"; done; }
want provision && { echo " provision:"; plan_line "./provision.sh $A_IP"; plan_line "./provision.sh $B_IP"; }
want bringup   && { echo " bringup:";   plan_line "./bringup_r2r3.sh $RUNG   # [RF] arms both radios"; }
want test      && { echo " test:";      plan_line "./test.sh ber -d 90       # [RF] keys the link"; }

if [ "$MODE" != run ]; then
  echo; echo "Plan only -- nothing was executed. To run it:  $0 run --yes${TO:+ --to $TO}"
  exit 0
fi

# ----------------------------------------------------------------- run ----
die(){ echo; echo "STOPPED: $1"; echo "Fix that, then re-run with --from <stage>."; exit 1; }
[ "$A_up" = 1 ] && [ "$B_up" = 1 ] || die "both boards must answer anyssh.sh before anything is flashed"

if want step0; then
  echo; echo "=== step0 ==="
  [ "$HAVE_K" = 1 ] || die "step0 needs $(basename "$KIMG").gz, which is not in images/ (see images/README.md). Use --from deploy or --from provision."
  [ -f "$KIMG" ] || [ "$NEEDK" = 0 ] || ( cd "$BKG" && gunzip -kf "$(basename "$KIMG").gz" ) || die "cannot unpack $KIMG.gz"
  for ip in "$A_IP" "$B_IP"; do
    probe "$ip"
    if [ "$P_uname" = "$KVER" ] && [ "${P_uio:-0}" -ge 3 ]; then echo "-- $ip already $KVER + $P_uio UIO nodes; skipping --"; continue; fi
    dtb=$(dtb_for "$ip"); [ -n "$dtb" ] || die "no system-qpsk.${ip##*.}.dtb.* in images/ for $ip"
    [ "$P_uname" = "$KVER" ] || "$D/deploy_kernel.sh" "$ip" "$KIMG" || die "deploy_kernel.sh $ip failed"
    "$D/deploy_dtb.sh" "$ip" "$dtb" || die "deploy_dtb.sh $ip failed"
    probe "$ip"
    [ "$P_uname" = "$KVER" ] || die "$ip came back on $P_uname, not $KVER"
    [ "${P_uio:-0}" -ge 3 ]  || die "$ip exposes ${P_uio:-0}/3 qpsk UIO nodes after the dtb deploy"
    echo "-- $ip: $P_uname, $P_uio/3 UIO nodes --"
  done
fi

if want deploy; then
  echo; echo "=== deploy ==="
  [ "$HAVE_IMG" = 1 ] || die "deploy needs the role BOOT.BINs named in images/CURRENT.txt, which are not in images/ (see images/README.md). Use --from provision."
  # one board at a time, each verified before the next -- the rollback .bak is
  # overwritten per run, so never have two boards in flight.
  for r in "A $A_IP" "B $B_IP"; do set -- $r
    probe "$2"; want_md5=$(role_md5 "$1")
    [ -n "$want_md5" ] || die "no role $1 line in images/CURRENT.txt"
    if [ "$P_boot" = "$want_md5" ]; then echo "-- $2 already carries role $1 ($want_md5); skipping --"; continue; fi
    "$D/deploy_image.sh" "$2" "$1" || die "deploy_image.sh $2 $1 failed"
    probe "$2"
    [ "$P_boot" = "$want_md5" ] || die "$2 /boot/BOOT.BIN is $P_boot after the flash, expected $want_md5"
    echo "-- $2: BOOT.BIN $P_boot --"
  done
fi

if want provision; then
  echo; echo "=== provision ==="
  for ip in "$A_IP" "$B_IP"; do
    probe "$ip"
    [ "${P_uio:-0}" -ge 3 ] || echo "  [warn] $ip exposes ${P_uio:-0}/3 qpsk UIO nodes -- provision.sh will build the 1 MB-carve host app (step0 not done)."
    "$D/provision.sh" "$ip" || die "provision.sh $ip failed"
    probe "$ip"
    [ "$P_tun" = 1 ]        || die "$ip has no executable /root/host_app_k5/qpsk_tun after provision"
    [ "${P_prof:-0}" -ge 2 ] || die "$ip is missing the rung-$RUNG profile pair after provision"
    [ "$P_wd" = 1 ]         || die "$ip has no /root/lock_watchdog.sh after provision"
  done
fi

if want bringup; then
  echo; echo "=== bringup  [RF: arming both radios] ==="
  for ip in "$A_IP" "$B_IP"; do probe "$ip"
    [ "$P_tun" = 1 ] && [ "${P_prof:-0}" -ge 2 ] || die "$ip is not provisioned; bring-up would load a profile onto an unprepared board"
  done
  "$D/bringup_r2r3.sh" "$RUNG" || die "bringup_r2r3.sh $RUNG failed"
fi

if want test; then
  echo; echo "=== test  [RF: keying the link] ==="
  "$D/test.sh" ber -d 90 || die "test.sh ber failed"
fi

echo; echo "=== done ($FROM..$TO) $(date -Is) ==="
[ "$TI" -lt "$(idx bringup)" ] && echo "Next, when you want the radios up:  ./bringup_r2r3.sh $RUNG"
exit 0
