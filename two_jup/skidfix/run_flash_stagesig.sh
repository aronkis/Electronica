#!/bin/bash
# Wrapper: take the single-actor rig lock (which also stops the sentinel, so it
# cannot fire a recovery bring-up mid-flash), run the fully-railed flash, release.
set -u
D=/mnt/onetb/scratch/qpsk-jupiter-modem/two_jup
. "$D/sim_repro/riglock.sh"
rig_lock flash_stagesig
trap 'rig_unlock' EXIT
bash "$D/skidfix/flash_148_stagesig.sh" "$@"
rc=$?
echo "FLASH_WRAPPER_RC=$rc"
exit $rc
