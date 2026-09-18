#!/usr/bin/env bash
# Camera on 148 -> QPSK RF hop -> a video WINDOW on 146's desktop. No WSL.
#
#   148  /dev/video0 (C270)                    146  DP-1 monitor, Xorg desktop
#    |                                          ^
#    | ffmpeg: MJPEG in -> H.264/mpegts 400k    | chromium --app window
#    v                                          | mjpeg_serve.py (localhost:8090)
#   tun0 10.66.0.2  ==== QPSK 1.9 GHz ====>  tun0 10.66.0.1
#
# 148 -> 146 is the PROVEN-HEALTHY direction (146 -> 148 is degraded in-repo),
# so the camera belongs on 148 and the monitor on 146. Backwards, and the only
# symptom is stream_webcam.sh's "no camera".
#
# WHY THIS REPLACES stream_webcam.sh
#   stream_webcam.sh captures on the machine you launch it from and relays UDP
#   through two base64 python helpers, because WSL is not on the 10.66.0.0/30
#   tun overlay and can only reach the boards over ethernet. Both endpoints are
#   now ON the overlay, so ffmpeg addresses 10.66.0.1 directly and the kernel
#   routes it through qpsk_tun. The relays are gone. Ethernet carries only ssh
#   control; not one video byte crosses it.
#
# WHY A BROWSER AND NOT A PLAYER (all four alternatives were tried and measured)
#   * ffplay        -- absent. The static build omits it; ffplay needs SDL2,
#                      which upstream cannot link statically.
#   * ffmpeg -f xv  -- "No X-Video adaptors present" on BOTH boards. Xorg falls
#                      back to the modesetting driver, which exposes no Xv.
#   * ffmpeg -f sdl -- not built, same SDL2 reason.
#   * ffmpeg -f fbdev /dev/fb0 -- works mechanically (needs -pix_fmt rgb565le;
#                      fb0 is 16 bpp), but Xorg owns the DRM scanout, so it
#                      shows nothing unless lightdm is stopped -- which kills
#                      the desktop AND the terminal you launched this from.
#                      Abandoned: a full-screen takeover is not a window.
#   Chromium is installed, so ffmpeg decodes to MJPEG, mjpeg_serve.py publishes
#   it on 127.0.0.1 as multipart/x-mixed-replace, and chromium --app renders it
#   in a plain window. X is never disturbed.
#
# PROCESS CONTROL: PIDFILES AND PORTS, NEVER pkill -f.
#   `pkill -f '[m]jpeg_serve'` killed the launching shell here on 2026-09-10:
#   the bracket trick fails when the plain string also appears elsewhere on the
#   same command line (the /usr/local/bin/mjpeg_serve.py path did). Same lesson
#   as bringup_r2r3.sh:189-191 -- "Use a PIDFILE, never pgrep -f."
set -u
D=$(cd "$(dirname "$0")" && pwd)
A=10.0.0.148; B=10.0.0.146      # ethernet (control plane only)
TA=10.66.0.2; TB=10.66.0.1      # tun0 overlay (the RF data plane)

DEV=${DEV:-/dev/video0}
SIZE=${SIZE:-640x480}   # SIZE=320x240 if 148's CPU struggles with the encode
INFMT=${INFMT:-mjpeg}   # the C270 emits MJPEG in hardware; yuyv422 melts USB
OUTFPS=${OUTFPS:-10}    # rate cap at the ENCODER, never at the v4l2 input
BR=${BR:-400k}          # the hop sustains ~2 Mbit/s; 400k leaves 4x margin
GOP=${GOP:-20}          # keyframe every 2 s at 10 fps = bounded loss recovery
PORT=${PORT:-5002}      # RF video; the preflight probe uses 5001
HTTP=${HTTP:-8090}      # localhost MJPEG for the browser, 146-internal only
JQ=${JQ:-6}             # MJPEG quality for the window, 2=best 31=worst
WINDOW=${WINDOW:-1000,700}
FULLSCREEN=${FULLSCREEN:-0}
LOGDIR=/tmp/qpsk_stream
SKIP_PREFLIGHT=${SKIP_PREFLIGHT:-0}
NOWINDOW=${NOWINDOW:-0}  # 1 = serve the stream but do not open chromium

CHECK_ONLY=0; STOP_ONLY=0
case "${1:-}" in
  --check) CHECK_ONLY=1 ;;
  --stop)  STOP_ONLY=1 ;;
  "")      ;;
  *) echo "usage: $0 [--check | --stop]" >&2; exit 2 ;;
esac

denoise(){ grep -v "post-quantum\|store now, decrypt later\|may need to be upgraded\|openssh.com/pq"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

# Run on whichever board owns $1. Launched FROM 146 in the normal case, so the
# whole display half stays local -- going out through sshd to reach yourself
# works, but it is slow and it breaks the moment sshd hiccups.
MYIPS=$(ip -4 -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
is_local(){ printf '%s\n' $MYIPS | grep -qx "$1"; }
run(){ local ip=$1; shift
  if is_local "$ip"; then bash -c "$*"
  else "$D/anyssh.sh" "$ip" "$*" 2>/dev/null | denoise; fi; }

# Ship script bodies as base64 rather than fighting three layers of quoting.
push(){ local ip=$1 path=$2 body=$3
  run "$ip" "echo $(printf %s "$body" | base64 -w0) | base64 -d > $path && chmod 755 $path"; }

# ------------------------------------------------------------------ shutdown --
# Every kill here is by PIDFILE, by PROCESS GROUP, or by TCP PORT.
#
# It is NOT `pkill -x chromium`, which was wrong twice over:
#   * the binary on these images is chromium-browser, not chromium (they are
#     RPi-derived -- rpi-chromium-mods is installed), and
#   * pkill -x matches /proc/PID/comm, which the kernel truncates to 15 chars,
#     so even `pkill -x chromium-browser` (16) matches nothing. procps warns
#     about patterns longer than 15 chars for exactly this reason.
# setsid makes chromium its own process-group leader, so killing -PID takes the
# zygote and every renderer with it. The bracket sweep is a safety net for the
# case where setsid forked and the pidfile caught the short-lived parent; [c]
# keeps it from matching its own shell, and that is only safe because the plain
# string appears nowhere else on this command line -- see the header note on
# exactly how that trick failed here before.
KILLWIN="P=\$(cat $LOGDIR/chromium.pid 2>/dev/null)
[ -n \"\$P\" ] && { kill -TERM -\$P 2>/dev/null; kill -TERM \$P 2>/dev/null; }
rm -f $LOGDIR/chromium.pid
pkill -f '[c]hromium-qpsk' 2>/dev/null
fuser -k -n tcp $HTTP 2>/dev/null
true"

stop_all(){
  run "$A" "[ -f $LOGDIR/tx.pid ] && kill \$(cat $LOGDIR/tx.pid) 2>/dev/null; rm -f $LOGDIR/tx.pid; true" >/dev/null 2>&1
  run "$B" "$KILLWIN" >/dev/null 2>&1
}
if [ "$STOP_ONLY" = 1 ]; then
  echo "== stopping =="
  stop_all
  echo "   148 camera stopped, 146 window closed, stream server stopped"
  echo "   (the desktop was never touched, so there is nothing to restore)"
  exit 0
fi

echo "== topology =="
echo "   camera  148 $A ($TA)  --RF-->  window  146 $B ($TB)"
is_local "$B" && echo "   running ON 146" || { is_local "$A" && echo "   running ON 148" \
  || echo "   running off-board (control only; no video touches this machine)"; }

# ------------------------------------------------------------------ hardware --
# Name the WRONG BOARD explicitly. "not found" sent the last debugging session
# looking for a camera fault when the camera was simply on the other board.
echo "== hardware =="
cam=$(run "$A" "ls $DEV >/dev/null 2>&1 && echo YES || echo NO" | tr -dc A-Z)
[ "$cam" = YES ] || die "no $DEV on 148 ($A). The camera must be on 148, the TX side.
  If it is plugged into 146, move it -- 146->148 is the degraded RF direction."
echo "   148 camera : $DEV"

xok=$(run "$B" "pgrep -x Xorg >/dev/null && echo YES || echo NO" | tr -dc A-Z)
[ "$xok" = YES ] || die "no Xorg running on 146 ($B) -- there is no desktop to put a window on.
  Start it:  systemctl start lightdm
  (an earlier version of this script stopped lightdm for framebuffer output;
   if the screen is a bare text console, that is why -- start lightdm.)"
# Resolve the browser by PATH lookup, never by a hardcoded name. These boards
# are RPi-derived, where the package and the binary are both chromium-browser;
# plain Debian calls it chromium. Assuming "chromium" made this script report
# "chromium is missing" on a board that had it installed all along.
CHROMIUM=$(run "$B" "command -v chromium-browser || command -v chromium || true" | tr -d ' \r\n')
[ -n "$CHROMIUM" ] || die "no chromium on 146 ($B) -- it is the only window-capable video sink here.
  Looked for both 'chromium-browser' and 'chromium' on PATH. It cannot be
  installed offline; it needs ~150 MB of Debian packages."
conn=$(run "$B" "cat /sys/class/drm/card0-DP-1/status 2>/dev/null" | tr -dc a-z)
echo "   146 screen : Xorg up, DP-1 $conn, $CHROMIUM"
for h in "$A" "$B"; do
  v=$(run "$h" "/usr/local/bin/ffmpeg -version 2>/dev/null | head -1 | cut -d' ' -f3")
  [ -n "$(printf %s "$v" | tr -dc 0-9)" ] || die "no /usr/local/bin/ffmpeg on $h -- run: bash $D/install_board_media.sh $h"
  echo "   $h  ffmpeg $v"
done
srv=$(run "$B" "ls /usr/local/bin/mjpeg_serve.py >/dev/null 2>&1 && echo YES || echo NO" | tr -dc A-Z)
[ "$srv" = YES ] || die "no /usr/local/bin/mjpeg_serve.py on 146 -- push it:
  base64 -w0 $D/mjpeg_serve.py | ssh root@$B 'base64 -d > /usr/local/bin/mjpeg_serve.py; chmod 755 \$_'"

# ------------------------------------------------------------------ preflight --
if [ "$SKIP_PREFLIGHT" != 1 ]; then
  echo "== preflight =="
  # tun0 loses its address on EVERY qpsk_tun restart: the DAEMON_CMD hardcoded
  # at bringup_r2r3.sh:197 relaunches the daemon without the ip addr step from
  # :169, the only place tun0 is ever addressed. The symptom is vicious -- RF
  # fine, dma_rx_ok climbing, and every frame landing in tun_drop.
  fix_tun(){ run "$1" "ip -4 addr show tun0 2>/dev/null | grep -q 'inet ' && { echo TUNOK; exit 0; }
 ip link show tun0 >/dev/null 2>&1 || { echo NOTUN; exit 1; }
 ip addr replace $2 peer $3 dev tun0 && ip link set tun0 up mtu 1516 && \
 ip route replace $3 dev tun0 advmss 1476 rto_min 25ms 2>/dev/null
 ip -4 addr show tun0 2>/dev/null | grep -q 'inet ' && echo TUNFIXED || echo TUNBAD"; }
  for spec in "$A $TA $TB" "$B $TB $TA"; do
    set -- $spec
    case "$(fix_tun "$1" "$2" "$3")" in
      *TUNOK*)    echo "   tun0 ok on $1" ;;
      *TUNFIXED*) echo "   tun0 was unaddressed on $1 -- repaired (daemon restart drops it)" ;;
      *NOTUN*)    die "no tun0 on $1 -- qpsk_tun is not running. Arm the link ON THE BOARD:
  WATCHDOG=0 GATE_DIR=B bash /root/Electronica/two_jup/bringup_r2r3.sh r3" ;;
      *)          die "could not address tun0 on $1. Run bringup_r2r3.sh r3" ;;
    esac
  done

  # Real one-way traffic in the SAME direction the video uses.
  #  * dma_rx_ok counts PAYLOAD frames, so an idle-but-healthy link reads 0.
  #  * ping is not a direction test: it needs 146->148, the degraded direction,
  #    and reports 100% loss on a hop happily carrying 92% one-way.
  #  * A STALE listener on 5001 steals the datagrams and fakes 0/100 "LINK DOWN".
  PROBE_RX='import socket
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(("'"$TB"'",5001)); s.settimeout(8)
n=0
while True:
    try: s.recv(4096); n+=1
    except Exception: break
open("/dev/shm/probe.out","w").write(str(n))'
  PROBE_TX='import socket,time
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.bind(("'"$TA"'",0))
for i in range(100): s.sendto(b"X"*1000,("'"$TB"'",5001)); time.sleep(0.01)'
  run "$B" "fuser -k -n udp 5001 2>/dev/null; rm -f /dev/shm/probe.out; true" >/dev/null
  push "$B" /dev/shm/probe_rx.py "$PROBE_RX" >/dev/null
  run "$B" "setsid python3 /dev/shm/probe_rx.py >/dev/null 2>&1 < /dev/null &" >/dev/null
  sleep 1
  push "$A" /dev/shm/probe_tx.py "$PROBE_TX" >/dev/null
  run "$A" "python3 /dev/shm/probe_tx.py" >/dev/null
  sleep 10
  got=$(run "$B" 'cat /dev/shm/probe.out 2>/dev/null || echo 0' | tr -dc 0-9); : "${got:=0}"
  echo "   one-way probe 148 -> 146 : $got/100 datagrams"
  [ "$got" -ge 60 ] || die "RF hop down or badly degraded ($got/100). Re-arm ON THE BOARD:
  WATCHDOG=0 GATE_DIR=B bash /root/Electronica/two_jup/bringup_r2r3.sh r3"
fi

if [ "$CHECK_ONLY" = 1 ]; then echo "== --check passed; hardware and hop are ready =="; exit 0; fi

trap 'echo; echo "== stopping =="; stop_all; echo "   done"; exit 0' INT TERM

# -------------------------------------------------------------- receiver side --
# Started FIRST so the decoder is listening before the first packet lands. It
# also self-restarts its ffmpeg every 2 s, so starting early costs nothing.
echo "== starting stream server on 146 =="
run "$B" "mkdir -p $LOGDIR
$KILLWIN" >/dev/null
sleep 1
run "$B" "setsid nohup python3 /usr/local/bin/mjpeg_serve.py \
  --port $HTTP --udp udp://$TB:$PORT --q $JQ \
  > $LOGDIR/serve.log 2>&1 < /dev/null & echo '   serving http://127.0.0.1:$HTTP/'"

# ----------------------------------------------------------------- camera side --
# DO NOT add -framerate to the v4l2 input. If it does not exactly match a rate
# the camera advertises for this format+size, the device still opens and ffmpeg
# still prints the input -- but no frame ever completes, and the only clue is
# "Output file is empty, nothing was encoded". Cap the rate at the encoder (-r).
#
# The C270 takes ~3.9 s to deliver its first frame (UVC startup, measured). That
# is not a hang; do not shorten timeouts below it.
#
# pkt_size=1316 = 7 x 188-byte TS packets. +28 bytes IP/UDP keeps it under
# tun0's 1516 MTU, so nothing fragments over the RF hop.
TX="echo \$\$ > $LOGDIR/tx.pid
exec /usr/local/bin/ffmpeg -hide_banner -loglevel warning \
 -f v4l2 -input_format $INFMT -video_size $SIZE -i $DEV \
 -an -c:v libx264 -preset ultrafast -tune zerolatency -profile:v baseline \
 -b:v $BR -maxrate $BR -bufsize $((${BR%k}/2))k -g $GOP -r $OUTFPS -pix_fmt yuv420p \
 -f mpegts -muxdelay 0 -muxpreload 0 -flush_packets 1 \
 'udp://$TB:$PORT?pkt_size=1316'"
echo "== starting camera on 148 =="
run "$A" "mkdir -p $LOGDIR
[ -f $LOGDIR/tx.pid ] && kill \$(cat $LOGDIR/tx.pid) 2>/dev/null
rm -f $LOGDIR/tx.pid; true" >/dev/null
push "$A" "$LOGDIR/tx.sh" "$TX" >/dev/null
run "$A" "setsid $LOGDIR/tx.sh > $LOGDIR/tx.log 2>&1 < /dev/null & echo '   camera armed'"

# --------------------------------------------------------------------- window --
if [ "$NOWINDOW" != 1 ]; then
  echo "== opening the window on 146 =="
  # --no-sandbox: chromium refuses to run as root without it, and these boards
  # are root-only. --disable-gpu: no usable GL here, and without it chromium
  # spends its startup retrying the GPU process.
  FS=""; [ "$FULLSCREEN" = 1 ] && FS="--start-fullscreen"
  run "$B" "XPID=\$(pgrep -x Xorg | head -1)
XA=\$(tr '\0' ' ' < /proc/\$XPID/cmdline | sed -n 's/.*-auth \([^ ]*\).*/\1/p')
rm -rf /tmp/chromium-qpsk
DISPLAY=:0 XAUTHORITY=\$XA setsid nohup $CHROMIUM \
  --app=http://127.0.0.1:$HTTP/ --no-sandbox --user-data-dir=/tmp/chromium-qpsk \
  --window-size=$WINDOW --window-position=80,40 --disable-gpu --no-first-run \
  --disable-features=TranslateUI --disable-session-crashed-bubble \
  --disable-infobars --noerrdialogs $FS \
  > $LOGDIR/chromium.log 2>&1 < /dev/null &
echo \$! > $LOGDIR/chromium.pid
echo \"   \$(basename $CHROMIUM) starting as pid \$(cat $LOGDIR/chromium.pid) (takes ~20 s on this hardware)\""
fi

echo
echo "== streaming =="
echo "   allow ~4 s for the C270's first frame, plus ~20 s for chromium."
echo "   stop with:  bash $0 --stop     (or Ctrl-C here)"
echo

# Report from BOTH ends. A one-ended report cannot distinguish a stalled camera
# from a hop that is dropping everything.
prev=0
while :; do
  sleep 5
  tx=$(run "$A" "[ -f $LOGDIR/tx.pid ] && kill -0 \$(cat $LOGDIR/tx.pid) 2>/dev/null && echo UP || echo DOWN" | tr -dc A-Z)
  rxb=$(run "$B" "cat /sys/class/net/tun0/statistics/rx_bytes 2>/dev/null" | tr -dc 0-9); : "${rxb:=0}"
  rate=$(( (rxb - prev) * 8 / 5000 )); prev=$rxb
  fps=$(run "$B" "grep -a '\[serve\]' $LOGDIR/serve.log 2>/dev/null | tail -1")
  printf "   camera=%-4s  RF in: %5d kbit/s   %s\n" "$tx" "$rate" "$(printf %s "$fps" | sed 's/\[serve\] //')"
  if [ "$tx" = DOWN ]; then
    echo "   camera side exited:"; run "$A" "tail -6 $LOGDIR/tx.log" | sed 's/^/     148 /'
    echo "   receiver log:";       run "$B" "tail -6 $LOGDIR/serve.log" | sed 's/^/     146 /'
    break
  fi
done
