#!/usr/bin/env bash
# Provision BOTH Jupiters, from this repo, for stream_board2board.sh.
#
# Run it HERE (WSL, or any machine holding this repo that can reach both boards
# over ethernet). After it passes, the boards are self-sufficient: the whole
# camera-to-window path runs on 146 + 148 with no third machine present.
#
#   148  camera / transmitter   ffmpeg + video4linux2 + libx264
#   146  monitor / receiver     ffmpeg + mpegts/h264/mjpeg, Xorg, chromium,
#                               mjpeg_serve.py
#   both                        the control scripts in /root/Electronica/two_jup
#
# WHY A SEPARATE SCRIPT FROM install_board_media.sh
#   install_board_media.sh provisions ONE board with the ffmpeg binary. This
#   drives it for both, adds the files that exist only here (mjpeg_serve.py and
#   stream_board2board.sh are untracked, so the boards' git checkouts do NOT
#   contain them), and then verifies the EXACT ffmpeg features each role uses --
#   not merely that "ffmpeg runs". A board can have ffmpeg and still be unable to
#   stream because the one indev or encoder it needs was not compiled in.
#
# OFFLINE BY DESIGN
#   The boards have no default route and DNS does not resolve, so apt cannot
#   fetch anything. Everything here is pushed over ssh from files already in this
#   repo. The one thing that CANNOT be installed offline is chromium (~150 MB of
#   Debian packages); it is already present on both boards, so this script
#   verifies it rather than installing it.
#
# IDEMPOTENT
#   Safe to re-run. Every push is md5-compared first, so the 49 MB ffmpeg
#   transfer is skipped when the binary already matches and a re-run costs
#   seconds. Nothing is ever left half-written: install_board_media.sh writes
#   .ffmpeg.new and mv's it into place, and each push here is md5-verified after
#   the fact.
set -u
D=$(cd "$(dirname "$0")" && pwd)
A=${A:-10.0.0.148}      # camera / transmitter
B=${B:-10.0.0.146}      # monitor / receiver
REPO=/root/Electronica/two_jup
BIN=/usr/local/bin
TMP=$(mktemp -d /tmp/install_stream_stack.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
fail=0

denoise(){ grep -v "post-quantum\|store now, decrypt later\|may need to be upgraded\|openssh.com/pq"; }
sh_(){ "$D/anyssh.sh" "$1" "$2" 2>/dev/null | denoise; }

# Push a local file, then confirm the md5 matches. A truncated transfer over
# password ssh is silent otherwise, and a half-written script does not fail
# here -- it fails much later, as a syntax error that reads like a code bug.
push(){ # $1=host $2=localfile $3=remotepath
  local h=$1 src=$2 dst=$3 want got
  [ -f "$src" ] || { printf '   ! %-28s MISSING LOCALLY (%s)\n' "$(basename "$dst")" "$src"; fail=1; return 1; }
  want=$(md5sum "$src" | cut -d' ' -f1)
  got=$(sh_ "$h" "md5sum $dst 2>/dev/null | cut -d' ' -f1" | tr -dc 0-9a-f)
  if [ "$want" = "$got" ]; then printf '   = %-28s unchanged\n' "$(basename "$dst")"; return 0; fi
  sh_ "$h" "mkdir -p $(dirname "$dst") && echo $(base64 -w0 "$src") | base64 -d > $dst && chmod 755 $dst" >/dev/null
  got=$(sh_ "$h" "md5sum $dst 2>/dev/null | cut -d' ' -f1" | tr -dc 0-9a-f)
  if [ "$want" = "$got" ]; then printf '   + %-28s -> %s\n' "$(basename "$src")" "$dst"
  else printf '   ! %-28s MD5 MISMATCH after push (want %s, got %s)\n' "$(basename "$src")" "${want:0:8}" "${got:0:8}"; fail=1; fi
}

# ------------------------------------------------------------------ verifier --
# Written to a file and piped in base64, NOT passed as an ssh argument. As an
# argument it would have to survive one round of local quoting plus one of
# remote re-parsing, which rules out ever using a single quote in it. Piping
# removes the whole class of problem.
cat > "$TMP/verify.sh" <<'VERIFY_EOF'
# ROLE is exported by the caller: tx (camera board) or rx (monitor board).
ROLE=${ROLE:-tx}
F=/usr/local/bin/ffmpeg
bad=""
p(){ printf "   %-26s %s\n" "$1" "$2"; }
# Fail only on what THIS role actually needs. The transmitter has no monitor and
# the receiver has no camera; reporting either as a fault would train us to
# ignore the output.
need(){ # $1=label $2=value $3=roles-that-require-it
  case "$3" in *"$ROLE"*) [ "$2" = ok ] || bad="$bad $1";; esac; }
has(){ $F -hide_banner "$1" 2>/dev/null | grep -qE "$2" && echo ok || echo MISSING; }

ver=$($F -version 2>/dev/null | head -1 | cut -d' ' -f3)
p ffmpeg "${ver:-MISSING}"
[ -n "$ver" ] || bad="$bad ffmpeg"

v4l2=$(has -devices video4linux2);  p "v4l2 indev (capture)" "$v4l2";  need v4l2   "$v4l2"  tx
x264=$(has -encoders " libx264 ");  p "libx264 encoder"      "$x264";  need libx264 "$x264" tx
ts=$(has -demuxers " mpegts ");     p "mpegts demuxer"       "$ts";    need mpegts  "$ts"   rx
h264=$(has -decoders " h264 ");     p "h264 decoder"         "$h264";  need h264    "$h264" rx
mje=$(has -encoders " mjpeg ");     p "mjpeg encoder"        "$mje";   need mjpeg-e "$mje"  rx
mjm=$(has -muxers " mjpeg ");       p "mjpeg muxer"          "$mjm";   need mjpeg-m "$mjm"  rx

py=$(python3 -V 2>&1 | cut -d' ' -f2); p python3 "${py:-MISSING}"
[ -n "$py" ] || bad="$bad python3"

# Syntax-check both, so a truncated push is caught now and not at 2 a.m.
# -r, not -x: stream_board2board.sh launches this as `python3 <path>`, so the
# exec bit is never consulted and demanding it would invent a failure.
# PYTHONPYCACHEPREFIX keeps py_compile from littering /usr/local/bin.
if [ -r @BIN_MJPEG@ ] && PYTHONPYCACHEPREFIX=/tmp/pycache python3 -m py_compile @BIN_MJPEG@ 2>/dev/null
then s=ok; else s=BROKEN; bad="$bad mjpeg_serve.py"; fi
p "mjpeg_serve.py" "$s"

if bash -n @REPO_STREAM@ 2>/dev/null; then s=ok; else s=BROKEN; bad="$bad stream_board2board.sh"; fi
p "stream_board2board.sh" "$s"

cam=$([ -e /dev/video0 ] && echo ok || echo none)
p "camera /dev/video0" "$cam$([ $ROLE = rx ] && echo '  (not needed on RX)')"
need camera "$cam" tx

xorg=$(pgrep -x Xorg >/dev/null && echo ok || echo none)
p "Xorg" "$xorg$([ $ROLE = tx ] && echo '  (not needed on TX)')"
need Xorg "$xorg" rx

# Resolve by PATH lookup, never by a hardcoded name. These boards are
# RPi-derived (rpi-chromium-mods), where both the package and the binary are
# chromium-browser; plain Debian calls it chromium. Checking only "chromium"
# reported a missing browser on boards that had it installed all along.
CB=$(command -v chromium-browser || command -v chromium || true)
if [ -n "$CB" ]; then chr=ok; cv="$CB $($CB --version 2>/dev/null | cut -d' ' -f2)"
else chr=MISSING; cv="MISSING -- no offline install possible"; fi
p chromium "$cv"
need chromium "$chr" rx

mon=$(cat /sys/class/drm/card*-DP-1/status 2>/dev/null | head -1)
p "DP-1 monitor" "${mon:-unknown}$([ $ROLE = tx ] && echo '  (not needed on TX)')"
[ "$ROLE" = rx ] && [ "$mon" != connected ] && bad="$bad monitor"

# tun0 is armed by bringup_r2r3.sh, not by this installer. Report it, never fail
# on it -- provisioning is valid whether or not the RF link happens to be up.
tun=$(ip -4 addr show tun0 2>/dev/null | grep -oE "inet [0-9.]+" | cut -d' ' -f2)
p "tun0 (RF overlay)" "${tun:-down -- arm with bringup_r2r3.sh r3}"

if [ -z "$bad" ]; then echo "   VERDICT: READY ($ROLE)"
else echo "   VERDICT: NOT READY ($ROLE) --$bad"; fi
VERIFY_EOF

# The verifier references two paths the caller owns; substitute them in rather
# than duplicating the constants inside the heredoc. @NAME@ placeholders, not
# $NAME -- a literal $ in a sed pattern is an end-of-line anchor in POSIX BRE,
# and only GNU's leniency would make it work.
sed -i "s|@BIN_MJPEG@|$BIN/mjpeg_serve.py|g; s|@REPO_STREAM@|$REPO/stream_board2board.sh|g" "$TMP/verify.sh"
VB64=$(base64 -w0 "$TMP/verify.sh")

# ---------------------------------------------------------------------- main --
provision(){ # $1=host $2=role-label
  local H=$1 role=$2 arch
  echo
  echo "########## $H -- $role ##########"
  arch=$(sh_ "$H" 'uname -m' | tr -dc 'a-z0-9_')
  if [ "$arch" != aarch64 ]; then
    echo "   ! unreachable, or wrong arch ('$arch') -- skipping this board"
    fail=1; return 1
  fi

  # The heavy one: static ffmpeg + board_webcam.py. Skips the transfer when the
  # binary is already identical, so this is cheap on a re-run.
  # Piped through tee, not captured to a file, so the "this takes a minute"
  # notice appears BEFORE the minute rather than after it. --line-buffered
  # matters here: without it grep holds the notice in its buffer and the
  # terminal sits silent for the whole transfer anyway.
  echo "-- ffmpeg (static aarch64, no dependencies) --"
  bash "$D/install_board_media.sh" "$H" 2>&1 \
    | tee "$TMP/media.$H.log" \
    | grep --line-buffered -E 'already installed|^== pushing|^ *this takes|PUSHED|^ERROR' \
    | sed 's/^ *//; s/^/   /'
  if [ "${PIPESTATUS[0]}" != 0 ]; then
    echo "   ! install_board_media.sh FAILED:"
    tail -6 "$TMP/media.$H.log" | sed 's/^/     /'
    fail=1
  fi

  # The files that exist only in this repo. Untracked, so `git pull` on the
  # board will never bring them.
  echo "-- stream stack --"
  push "$H" "$D/mjpeg_serve.py"        "$BIN/mjpeg_serve.py"
  push "$H" "$D/stream_board2board.sh" "$REPO/stream_board2board.sh"

  # Control-plane prerequisites -- required on the RX board ONLY. 146 is the
  # orchestrator: stream_board2board.sh runs there, reaches 148 with anyssh.sh
  # (which needs askpass.sh), and bringup_r2r3.sh arms the link from there.
  # 148 is a pure endpoint -- nothing ever executes on it except the base64
  # body pushed to it over ssh -- so it needs no checkout at all. Measured
  # 2026-09-11: 148's two_jup/ holds nothing but what this installer pushes,
  # and demanding a full checkout there produced three false alarms.
  # anyssh.sh and askpass.sh are invoked as bare paths so they need the exec
  # bit; bringup_r2r3.sh is run as `bash <path>`, so readable is enough.
  echo "-- control plane --"
  if [ "$role" = tx ]; then
    echo "   - not needed on the TX board; 146 drives 148 over ssh."
    echo "     (to swap roles -- camera on 146 -- 148 would then need a checkout)"
  else
    local f t ok
    for f in anyssh.sh:-x askpass.sh:-x bringup_r2r3.sh:-r; do
      t=${f#*:}; f=${f%:*}
      ok=$(sh_ "$H" "[ $t $REPO/$f ] && echo YES || echo NO" | tr -dc A-Z)
      if [ "$ok" = YES ]; then printf '   = %-28s present\n' "$f"
      else printf '   ! %-28s MISSING (or not %s) in %s\n' "$f" "${t#-}" "$REPO"; fail=1; fi
    done
  fi

  echo "-- verify ($role) --"
  sh_ "$H" "echo $VB64 | base64 -d | ROLE=$role bash" | tee "$TMP/verify.$H.out"
  grep -q 'VERDICT: READY' "$TMP/verify.$H.out" || fail=1
}

echo "############ provisioning $A (TX) and $B (RX) ############"
provision "$A" tx
provision "$B" rx

echo
echo "############ summary ############"
if [ "$fail" = 0 ]; then
  cat <<EOF
   Both boards are provisioned and verified READY.

   Everything below runs ON 146. This machine can now be unplugged -- no part of
   the video path touches it.

   1. Arm the RF link. Only needed after a reboot; it persists otherwise.
        WATCHDOG=0 GATE_DIR=B bash $REPO/bringup_r2r3.sh r3

      WATCHDOG=0 is deliberate. The watchdog block relaunches qpsk_tun with a
      DAEMON_CMD that omits the tun0 addressing step, and on 146 the byte-plane
      wedge detector can never clear (0x1C0/0x1C4/0x1C8 always read 0 on that
      board's pre-fsv2 bitstream), so it restarts the daemon forever and leaves
      tun0 without an address.
      GATE_DIR=B gates on the 148->146 direction only -- the direction the video
      travels. The default 'both' also demands 146->148, which is degraded.

   2. Check hardware and the hop without opening anything:
        bash $REPO/stream_board2board.sh --check

   3. Show the camera in a window on 146's desktop:
        bash $REPO/stream_board2board.sh

   4. Stop it:
        bash $REPO/stream_board2board.sh --stop
EOF
else
  cat <<EOF
   INCOMPLETE -- see the '!' lines and any 'VERDICT: NOT READY' above.

   Nothing was left half-written: every push is md5-verified and the ffmpeg
   binary is mv'd into place only after it lands whole, so re-running this
   script is safe and skips whatever already succeeded.

   If chromium is the only thing missing on $B, it cannot be fixed from here --
   it has no offline installer and needs ~150 MB of Debian packages.
EOF
  exit 1
fi
