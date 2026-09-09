#!/bin/bash
# beat_timeline_go.sh -- rig-unit wrapper: env (SECS/OUT/DRY) comes from launch_rig_unit.sh's --setenv.
exec bash "$(dirname "$0")/beat_timeline.sh"
