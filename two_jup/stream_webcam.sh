#!/usr/bin/env bash
# Stream a WSL webcam over the QPSK RF hop and play it back on the WSL desktop.
#
#   WSL /dev/video0 -> ffmpeg(H.264/MPEG-TS) -> ssh stdin -> 148
#     -> udptx.py -> tun0 10.66.0.2 -> [ QPSK 1.9 GHz RF ] -> 146 tun0 10.66.0.1
#       -> udprx.py -> ssh stdout -> WSL -> ffplay
#
# WHY THIS DIRECTION ONLY (148 -> 146):
#   MPEG-TS over UDP is one-way and needs no return path, so the demo runs over
#   whichever direction is healthy. Historically that is 148->146. Both ssh legs
#   carry their data over ETHERNET (10.0.0.x); only the tun0 hop is RF.
#
# PREREQUISITES: the link must already be up and IN LOCK. The preflight below
#   checks this and ABORTS with a diagnosis rather than showing an empty window.
#   If it reports LINK DOWN, re-arm with:  bash bringup_r2r3.sh r3
#
# NOTE: the relay helpers live in /dev/shm on the boards, so they do NOT survive
#   a board reboot. This script re-deploys them every run, which is idempotent.
#
# DEBUGGING: every stage writes a log under $LOGDIR (default /tmp/qpsk_stream).
#   Nothing is sent to /dev/null -- an earlier version hid all errors, which made
#   a dead RF link look identical to a broken player.
set -u
D=$(cd "$(dirname "$0")" && pwd)
A=10.0.0.148; B=10.0.0.146
DEV=${DEV:-/dev/video0}
SIZE=${SIZE:-320x240}
# DO NOT request an input framerate by default. If the value does not exactly
# match a rate the camera advertises for this format+size, v4l2 still opens the
# device and ffmpeg still reports the input -- but no frame ever completes, and
# the only clue is "Output file is empty, nothing was encoded". The Logitech
# 046d:0825 advertises 30 fps for MJPG 320x240; asking for 15 produced 0 bytes
# for 40 s while a single -frames:v 1 grab worked. Set FPS only to override.
FPS=${FPS:-}            # empty = let the camera choose its native rate
OUTFPS=${OUTFPS:-15}    # rate cap applied at the ENCODER, which always works
INFMT=${INFMT:-mjpeg}   # mjpeg or yuyv422; mjpeg needs far less USB bandwidth
BR=${BR:-400k}          # keep well under the ~2 Mbit/s the hop sustains
DUR=${DUR:-}            # e.g. DUR=15 for a bounded run; empty = stream until Ctrl-C
LOGDIR=${LOGDIR:-/tmp/qpsk_stream}
SKIP_PREFLIGHT=${SKIP_PREFLIGHT:-0}
mkdir -p "$LOGDIR"

# pipe-capable ssh: identical to anyssh.sh but WITHOUT its `< /dev/null`, which
# would otherwise starve the sender of its stdin stream.
sshin(){ IP="$1"; shift
  SSH_ASKPASS="$D/askpass.sh" SSH_ASKPASS_REQUIRE=force DISPLAY=:0 \
    setsid -w ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no root@"$IP" "$@"; }

# ssh noise filter: the boards run an old sshd that triggers a post-quantum warning.
denoise(){ grep -v "post-quantum\|store now, decrypt later\|may need to be upgraded\|openssh.com/pq" ; }

die(){ echo "ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------- preflight --
# A dead RF link and a broken player both present as "no window". Tell them apart
# BEFORE launching anything, and say which one it is.
if [ "$SKIP_PREFLIGHT" != 1 ]; then
  echo "== preflight =="
  [ -e "$DEV" ] || die "$DEV does not exist. Is the webcam attached to WSL? (usbipd attach --wsl --busid <id>)"

  # tun0 loses its address every time qpsk_tun restarts, because the DAEMON_CMD
  # hardcoded at bringup_r2r3.sh:214 relaunches the daemon WITHOUT re-running the
  # ip addr/link/route step. The symptom is brutal to read: the RF link is fine
  # and dma_rx_ok climbs, but every frame lands in tun_drop. Repair it here --
  # these commands are idempotent and identical to bringup_r2r3.sh:166-168.
  fix_tun(){ # $1=host  $2=self  $3=peer
    "$D/anyssh.sh" $1 "ip -4 addr show tun0 2>/dev/null | grep -q 'inet ' && { echo TUNOK; exit 0; }
 ip link show tun0 >/dev/null 2>&1 || { echo NOTUN; exit 1; }
 ip addr replace $2 peer $3 dev tun0 && ip link set tun0 up mtu 1516 && \
 ip route replace $3 dev tun0 advmss 1476 rto_min 25ms 2>/dev/null
 ip -4 addr show tun0 2>/dev/null | grep -q 'inet ' && echo TUNFIXED || echo TUNBAD" 2>/dev/null | denoise; }
  for spec in "$A 10.66.0.2 10.66.0.1" "$B 10.66.0.1 10.66.0.2"; do
    set -- $spec
    case "$(fix_tun $1 $2 $3)" in
      *TUNOK*)    echo "  tun0 ok on $1" ;;
      *TUNFIXED*) echo "  tun0 was unaddressed on $1 -- repaired (daemon restart drops it)" ;;
      *NOTUN*)    die "no tun0 device on $1 -- qpsk_tun is not running. Run: bash bringup_r2r3.sh r3" ;;
      *)          die "could not address tun0 on $1. Run: bash bringup_r2r3.sh r3" ;;
    esac
  done

  # Probe the hop with real one-way traffic on the SAME direction the video uses.
  #
  # Two traps this avoids:
  #  * Watching dma_rx_ok passively proves nothing -- it counts PAYLOAD frames, so
  #    on an idle link it sits at 0 even when the link is perfectly healthy.
  #  * ping is not a direction test. It needs the return path 146->148, which is
  #    the known-degraded direction, so it reports 100% loss on a hop that is in
  #    fact carrying 92% of one-way traffic.
  PROBE_RX='import socket,sys,os
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(("10.66.0.1",5001)); s.settimeout(8)
n=0
while True:
    try: s.recv(4096); n+=1
    except Exception: break
open("/dev/shm/probe.out","w").write(str(n))'
  PROBE_TX='import socket,time
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.bind(("10.66.0.2",0))
for i in range(100): s.sendto(b"X"*1000,("10.66.0.1",5001)); time.sleep(0.01)'
  "$D/anyssh.sh" $B "rm -f /dev/shm/probe.out; echo $(printf %s "$PROBE_RX" | base64 -w0) | base64 -d > /dev/shm/probe_rx.py
  setsid python3 /dev/shm/probe_rx.py >/dev/null 2>&1 &" 2>/dev/null | denoise
  sleep 1
  "$D/anyssh.sh" $A "echo $(printf %s "$PROBE_TX" | base64 -w0) | base64 -d > /dev/shm/probe_tx.py; python3 /dev/shm/probe_tx.py" 2>/dev/null | denoise
  sleep 10
  got=$("$D/anyssh.sh" $B 'cat /dev/shm/probe.out 2>/dev/null || echo 0' 2>/dev/null | denoise | tr -dc 0-9)
  : "${got:=0}"
  echo "  one-way probe $A -> $B : $got/100 datagrams"
  if [ "$got" -lt 50 ]; then
    echo "  ---------------------------------------------------------------" >&2
    echo "  LINK DOWN: only $got of 100 datagrams crossed the hop." >&2
    echo "  The demodulator is out of lock -- video cannot get through." >&2
    echo "  Re-arm with:  WATCHDOG=0 GATE_TRIES=12 bash $D/bringup_r2r3.sh r3" >&2
    echo "  (stop any lock_watchdog.sh first, by exact PID -- a register read" >&2
    echo "   during an arm hangs the board's PS until a power cycle)" >&2
    echo "  ---------------------------------------------------------------" >&2
    die "aborting; the RF link carries too little traffic to stream"
  fi
fi

# ------------------------------------------------------------------ relays --
# udptx/udprx write a pidfile so they can be reaped WITHOUT pgrep -f. A pgrep -f
# pattern that appears in the reaping shell's own command line matches that shell
# and kills it (see bringup_r2r3.sh:207) -- which silently prevented the receiver
# from ever being deployed. The pidfile is validated against /proc/<pid>/cmdline
# so a recycled PID is never killed.
TXPY=$(cat <<'PY' | base64 -w0
import socket,sys,os
open("/dev/shm/udptx.pid","w").write(str(os.getpid()))
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
s.bind(("10.66.0.2",0))
dst=("10.66.0.1",5000); n=0
r=sys.stdin.buffer
while True:
    b=r.read(1316)          # 1316 = 7 x 188-byte TS packets, the standard UDP/TS payload
    if not b: break
    try: s.sendto(b,dst); n+=1
    except Exception: pass
sys.stderr.write("udptx sent %d datagrams\n"%n)
PY
)
RXPY=$(cat <<'PY' | base64 -w0
import socket,sys,os
open("/dev/shm/udprx.pid","w").write(str(os.getpid()))
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET,socket.SO_RCVBUF,4*1024*1024)
s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(("10.66.0.1",5000)); s.settimeout(30)
w=sys.stdout.buffer; n=0
while True:
    try: d=s.recv(4096)
    except Exception: break
    w.write(d); w.flush(); n+=1
sys.stderr.write("udprx got %d datagrams\n"%n)
PY
)

# reap by pidfile, verifying the PID really is our relay before signalling it
REAP='P=/dev/shm/RELAY.pid; if [ -f $P ]; then pid=$(cat $P); if [ -n "$pid" ] && [ -d /proc/$pid ] && tr "\0" " " < /proc/$pid/cmdline | grep -q RELAY; then kill -9 $pid 2>/dev/null; fi; rm -f $P; fi'

echo "== deploying relays =="
"$D/anyssh.sh" $A "${REAP//RELAY/udptx}
 echo $TXPY | base64 -d > /dev/shm/udptx.py" 2>&1 | denoise
"$D/anyssh.sh" $B "${REAP//RELAY/udprx}
 echo $RXPY | base64 -d > /dev/shm/udprx.py" 2>&1 | denoise

# ------------------------------------------------------- receiver + player --
echo "== receiver + player  (logs in $LOGDIR) =="
# probesize/analyzeduration must be large enough for ffplay to find the MPEG-TS
# PAT/PMT. The old value of 32 bytes made ffplay give up before it ever saw a
# stream, so no window appeared even when video was arriving.
"$D/anyssh.sh" $B 'python3 /dev/shm/udprx.py' 2>"$LOGDIR/rx.err" \
  | tee "$LOGDIR/rx.ts" \
  | ffplay -hide_banner -loglevel info -fflags nobuffer -flags low_delay \
           -err_detect ignore_err -probesize 100000 -analyzeduration 1000000 \
           -window_title "QPSK RF webcam (via 146)" -i - 2>"$LOGDIR/player.log" &
PLAYER=$!
trap 'kill $PLAYER 2>/dev/null' EXIT INT TERM
sleep 3

# ------------------------------------------------------------- capture/tx --
echo "== capturing $DEV ($INFMT $SIZE, ${OUTFPS}fps out) -> $A  (Ctrl-C to stop) =="
ffmpeg -hide_banner -loglevel warning \
  -f v4l2 -input_format "$INFMT" -video_size "$SIZE" ${FPS:+-framerate $FPS} -i "$DEV" \
  ${DUR:+-t $DUR} \
  -r "$OUTFPS" \
  -c:v libx264 -preset ultrafast -tune zerolatency \
  -b:v "$BR" -maxrate "$BR" -bufsize 200k -g "$OUTFPS" -pix_fmt yuv420p \
  -f mpegts - 2>"$LOGDIR/capture.log" \
  | sshin $A 'python3 /dev/shm/udptx.py' 2>&1 | denoise

echo
echo "== done =="
echo "  received $(stat -c%s "$LOGDIR/rx.ts" 2>/dev/null || echo 0) bytes  -> $LOGDIR/rx.ts"
echo "  logs: $LOGDIR/{capture,player}.log  $LOGDIR/rx.err"
wait $PLAYER 2>/dev/null
