#!/bin/bash
# deploy_daemon_go.sh BOARD=148|146 FLAGS="..." -- T0c (happy-bubbling-owl): scp the
# host_app_k5 sources (the exact list capture_r3.sh uses -- qpsk_uio.c/.h already in
# it) and build on-board with the exact gcc line two_jup/comb/README_hostlog.md is
# supposed to record (Task 1/T0a writes that file; it does not exist yet as of this
# task, so this script falls back to capture_r3.sh's own build line +
# -DQPSK_RXQ_STAT, exactly as the plan directs -- re-check README_hostlog.md before
# trusting this fallback once Task 1 lands it).
#
# gcc line (capture_r3.sh, board B / 146 branch) + -DQPSK_RXQ_STAT:
#   gcc -O2 -Wall -DQPSK_CARVE_2MB [-DQPSK_ARQ_NAKSTAT if already deployed] \
#       -DQPSK_RXQ_STAT $FLAGS -o qpsk_tun \
#       qpsk_tun.c qpsk_frame.c qpsk_ber.c qpsk_seq.c qpsk_uio.c
#   gcc -O2 -Wall -o qpsk_perf qpsk_perf.c
#
# After the build: verify `strings qpsk_tun | grep -c nakstat` == 4 on 148 (ABORT if
# not -- the same NAK-path-counter regression capture_r3.sh's own guard exists to
# catch) and print the daemon md5.
#
# NAKSTAT abort gate is 148-ONLY (task-3-fix1 I-1; precedent restore_known_good.sh:64
# "(148 must be 4)" and soak_run.sh:19 -- nakstat==4 is a 148-specific fingerprint,
# 146 is not expected to carry it). BOARD=146 records the same count in meta.txt as
# informational only and never aborts on it. In DRY mode NAKSTAT_N is per-board
# (148 fabricates 4 -- the passing fingerprint; 146 fabricates 0 -- what an
# un-instrumented 146 build actually looks like) so a test can catch a false 146
# abort regression rather than both boards being hardcoded to the same passing value.
#
# -DQPSK_RXQ_STAT is applied to BOTH boards here, unconditionally, unlike
# capture_r3.sh (which scopes it to board B/146 only, capture_r3.sh:~123, "board A
# (148) must rebuild to a functionally untouched binary"). This IS intentional for
# this campaign (plan T0a: compile -DQPSK_RXQ_STAT for the instrumented build) --
# note that a deployed instrumented build therefore trips restore_known_good.sh:65's
# rxqstat==0 rail BY DESIGN; get an explicit operator confirmation before the first
# real 148 deploy with this script.
set -u
D=$(cd "$(dirname "$0")" && pwd)          # two_jup/comb
TJ=$(cd "$D/.." && pwd)                   # two_jup
ROOT=$(cd "$TJ/.." && pwd)
SRC=$ROOT/host_app_k5
DRY=${DRY:-1}
BOARD=${BOARD:?usage: BOARD=148|146 deploy_daemon_go.sh}
FLAGS=${FLAGS:-}
README=$D/README_hostlog.md

case "$BOARD" in
  148) IP=10.0.0.148;;
  146) IP=10.0.0.146;;
  *) echo "BOARD must be 148 or 146" >&2; exit 2;;
esac

TS=$(date +%Y%m%d_%H%M%S)
OUT=${OUT:-$D/runs/${TS}_deploy_${BOARD}}
mkdir -p "$OUT"
log(){ echo "$(date -Is) $*" | tee -a "$OUT/run.log"; }

# exact scp file list (matches capture_r3.sh's SRC list; qpsk_uio.c/.h already in it).
FILES="qpsk_tun.c qpsk_frame.c qpsk_frame.h qpsk_hw.h qpsk_ber.c qpsk_ber.h qpsk_seq.c qpsk_seq.h qpsk_uio.c qpsk_uio.h qpsk_join.h qpsk_perf.c"

if [ -f "$README" ]; then
  GCC_SRC="README_hostlog.md ($README)"
  log "using build line from $README"
else
  GCC_SRC="capture_r3.sh's line + -DQPSK_RXQ_STAT (README_hostlog.md not yet written by Task 1)"
  log "$README absent -- falling back to $GCC_SRC"
fi

# DRY-time cross-check (task-3-fix1 minor): every FILES entry must exist under
# host_app_k5/ -- a future desync (FILES entry added before the source lands, or
# vice versa) would otherwise only fail for real at DRY=0 (scp exits nonzero).
for f in $FILES; do
  [ -f "$SRC/$f" ] || { log "FAIL: $f listed in FILES but missing from $SRC/"; echo "DEPLOY_DAEMON_FAIL missing_source $f"; exit 1; }
done

log "board=$BOARD ip=$IP flags=[$FLAGS] dry=$DRY -> $OUT"

if [ "$DRY" = 1 ]; then
  log "[dry] mkdir -p /root/host_app_k5 on $IP"
  for f in $FILES; do log "[dry] scp $SRC/$f root@$IP:/root/host_app_k5/"; done
  log "[dry] gcc -O2 -Wall -DQPSK_CARVE_2MB -DQPSK_RXQ_STAT $FLAGS -o qpsk_tun qpsk_tun.c qpsk_frame.c qpsk_ber.c qpsk_seq.c qpsk_uio.c"
  log "[dry] gcc -O2 -Wall -o qpsk_perf qpsk_perf.c"
  BUILD_OK=1
  NAKSTAT_N=4; [ "$BOARD" = 146 ] && NAKSTAT_N=0
  DAEMON_MD5="dry-no-board"
else
  "$TJ/anyssh.sh" "$IP" 'mkdir -p /root/host_app_k5' 2>/dev/null
  SCPPUT(){ SSH_ASKPASS="$TJ/askpass.sh" SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp -o StrictHostKeyChecking=no -o ConnectTimeout=15 -o PreferredAuthentications=password -o PubkeyAuthentication=no "$@" </dev/null 2>>"$OUT/scp_err.txt"; }
  FPATHS=""; for f in $FILES; do FPATHS="$FPATHS $SRC/$f"; done
  SCPPUT $FPATHS root@"$IP":/root/host_app_k5/ || { log "scp FAILED"; echo "DEPLOY_DAEMON_FAIL scp"; exit 1; }
  # preserve deployed NAK-stat instrumentation the same way capture_r3.sh does
  NAKKEEP=$("$TJ/anyssh.sh" "$IP" 'strings /root/host_app_k5/qpsk_tun 2>/dev/null | grep -q "nakstat:" && echo "-DQPSK_ARQ_NAKSTAT" || echo ""' 2>/dev/null)
  R=$("$TJ/anyssh.sh" "$IP" "cd /root/host_app_k5 && gcc -O2 -Wall -DQPSK_CARVE_2MB $NAKKEEP -DQPSK_RXQ_STAT $FLAGS -o qpsk_tun \
        qpsk_tun.c qpsk_frame.c qpsk_ber.c qpsk_seq.c qpsk_uio.c 2>/tmp/gcc.err \
        && gcc -O2 -Wall -o qpsk_perf qpsk_perf.c 2>>/tmp/gcc.err \
        && echo BUILD_OK || { echo BUILD_FAIL; cat /tmp/gcc.err; }" 2>/dev/null)
  echo "$R" >> "$OUT/build.log"
  echo "$R" | grep -q BUILD_OK && BUILD_OK=1 || BUILD_OK=0
  NAKSTAT_N=$("$TJ/anyssh.sh" "$IP" 'strings /root/host_app_k5/qpsk_tun 2>/dev/null | grep -c nakstat' 2>/dev/null)
  DAEMON_MD5=$("$TJ/anyssh.sh" "$IP" 'md5sum /root/host_app_k5/qpsk_tun 2>/dev/null | cut -c1-32' 2>/dev/null)
fi

# ABORT gate: strings | grep -c nakstat must == 4, but ONLY on 148 (task-3-fix1 I-1).
# 146 records the count as informational and never gates the deploy on it.
NAKSTAT_OK=1
NAKSTAT_NOTE="informational only (BOARD=$BOARD, gate is 148-only)"
if [ "$BOARD" = 148 ]; then
  NAKSTAT_OK=0
  [ "${NAKSTAT_N:-0}" = 4 ] && NAKSTAT_OK=1
  NAKSTAT_NOTE="gate applies (BOARD=148)"
fi

{
  echo "board=$BOARD ip=$IP flags=[$FLAGS] dry=$DRY"
  echo "gcc_line_source=$GCC_SRC"
  echo "build_ok=$BUILD_OK"
  echo "nakstat_strings=$NAKSTAT_N (need 4; $NAKSTAT_NOTE)"
  echo "nakstat_gate_pass=$NAKSTAT_OK"
  echo "daemon_md5=$DAEMON_MD5"
  echo "ts=$(date -Is)"
} > "$OUT/meta.txt"

cat "$OUT/meta.txt"
if [ "$BUILD_OK" != 1 ]; then echo "DEPLOY_DAEMON_FAIL build"; exit 1; fi
if [ "$NAKSTAT_OK" != 1 ]; then echo "DEPLOY_DAEMON_ABORT nakstat_strings=$NAKSTAT_N != 4 (148-only gate)"; exit 4; fi
echo "DEPLOY_DAEMON_OK board=$BOARD daemon_md5=$DAEMON_MD5"
