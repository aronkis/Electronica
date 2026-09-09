# agentstate.sh -- per-agent JSON state fragment. One file per agent, so there
# is no shared-file write race. Atomic (temp + mv): a reader never sees a
# partial write. Serves both liveness heartbeat and dashboard data.
#
# All JSON encoding is delegated to python3's json.dumps (values are passed
# via argv, never interpolated into the python source text) so scalars,
# step-status values and findings can contain quotes, backslashes and
# newlines without corrupting the fragment.
RIG_DIR="${RIG_DIR:-/home/tcollins/modem-status}"
AGENT_DIR="$RIG_DIR/agents"

agent_state_init(){
  case "$1" in
    */*|"") echo "agent_state_init: invalid agent name: '$1'" >&2; return 1 ;;
  esac
  AS_AGENT="$1"; AS_HOST="$2"; AS_BLOCKS="$3"
  AS_STARTED="$(date -Is)"; AS_PHASE="init"; AS_RIG="false"
  AS_STEP_KEYS=(); AS_STEP_VALS=(); AS_FINDINGS=()
  mkdir -p "$AGENT_DIR"
}

agent_state_set(){
  case "$1" in
    phase)    AS_PHASE="$2" ;;
    rig_held) AS_RIG="$2" ;;
    *)        : ;;  # unrecognized key: silent no-op by design (see brief)
  esac
}

agent_state_step(){ AS_STEP_KEYS+=("$1"); AS_STEP_VALS+=("$2"); }
agent_state_finding(){ AS_FINDINGS+=("$1"); }

agent_state_flush(){
  local f="$AGENT_DIR/$AS_AGENT.json" t="$AGENT_DIR/.$AS_AGENT.tmp"
  local hb; hb="$(date -Is)"
  local nsteps=${#AS_STEP_KEYS[@]}
  local nfind=${#AS_FINDINGS[@]}
  local args=(
    "$AS_AGENT" "$AS_HOST" "$AS_BLOCKS" "$AS_PHASE" "$AS_RIG"
    "$AS_STARTED" "$hb" "$f" "$t" "$nsteps"
  )
  local i
  for ((i=0;i<nsteps;i++)); do args+=("${AS_STEP_KEYS[$i]}"); done
  for ((i=0;i<nsteps;i++)); do args+=("${AS_STEP_VALS[$i]}"); done
  args+=("$nfind")
  for ((i=0;i<nfind;i++)); do args+=("${AS_FINDINGS[$i]}"); done

  python3 - "${args[@]}" <<'PY'
import json, os, sys

a = sys.argv[1:]
i = 0
def take():
    global i
    v = a[i]; i += 1
    return v

agent = take(); host = take(); blocks = take(); phase = take(); rig_held = take()
started = take(); heartbeat = take(); dest = take(); tmp = take()
nsteps = int(take())
keys = a[i:i+nsteps]; i += nsteps
vals = a[i:i+nsteps]; i += nsteps
nfind = int(take())
findings = a[i:i+nfind]; i += nfind

step_status = {}
for k, v in zip(keys, vals):
    step_status[k] = v

doc = {
    "agent": agent,
    "host": host,
    "blocks": blocks,
    "phase": phase,
    "rig_held": rig_held,
    "started": started,
    "last_heartbeat": heartbeat,
    "step_status": step_status,
    "findings": findings,
}

with open(tmp, "w") as fh:
    json.dump(doc, fh, indent=2)
    fh.write("\n")
os.replace(tmp, dest)
PY
}
