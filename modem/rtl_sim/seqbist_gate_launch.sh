#!/bin/bash
# seqbist_gate_launch.sh -- launch the SEQ-BIST T0c sim gates (G1-G4) from
# seqbist_gate_runs.txt as `systemd-run --user` transient units (never harness
# background tasks: those are reaped at session exit -- MEMORY
# background-jobs-systemd-run).  Host-only, CPU-only, no board contact.
#
# Each unit's wrapper prints `SEQBIST_GATE_RUN_EXIT=<code>` AFTER the binary
# returns; that trailer is the only proof the process actually exited and
# seqbist_gate_score.py refuses to score a run without it (the txfix lesson:
# _csv/_summary files are written incrementally and scoring them mid-flight
# silently scores partial data as final).
#
#   ./seqbist_gate_launch.sh            # launch every gate in the manifest
#   ./seqbist_gate_launch.sh G2 G4      # launch just these
set -u
cd "$(dirname "$0")" || exit 1
R="$(pwd)"
BIN=$R/obj_seqbist_gate/Vwrap_byte_seqbist
TS=$(date +%s)
mkdir -p beat_runs

[ -x "$BIN" ] || { echo "FATAL: no harness at $BIN (run build_seqbist_gate.sh)" >&2; exit 1; }

want=("$@")
n=0
while IFS='|' read -r gid nf skip corr fill gap pfx force maxm filler; do
  case "$gid" in ''|\#*) continue;; esac
  if [ ${#want[@]} -gt 0 ]; then
    hit=0; for w in "${want[@]}"; do [ "$w" = "$gid" ] && hit=1; done
    [ $hit -eq 1 ] || continue
  fi
  log="$R/beat_runs/seqbist_gate_${gid}.log"
  unit="seqbist-gate-${gid,,}-${TS}-$$"
  : > "$log"
  systemd-run --user --collect --unit="$unit" \
    --working-directory="$R" \
    -p StandardOutput=append:"$log" -p StandardError=append:"$log" \
    /bin/bash -c "echo SEQBIST_GATE_LAUNCH id=$gid args='$nf $skip $corr $fill $gap $pfx $force $maxm'; \
                  '$BIN' '$nf' '$skip' '$corr' '$fill' '$gap' '$pfx' '$force' '$maxm'; \
                  echo SEQBIST_GATE_RUN_EXIT=\$?" \
    && echo "LAUNCHED $unit -> $log" || echo "LAUNCH_FAILED $gid"
  n=$((n+1))
  sleep 1
done < seqbist_gate_runs.txt
echo "SEQBIST_GATE_LAUNCH_DONE n=$n"
