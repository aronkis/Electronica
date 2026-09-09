#!/bin/bash
# txfix_flash_go.sh -- rig-unit wrapper: env (FLASH_MD5/FLASH_BAK/FLASH_TAG/DRY) comes from launch_rig_unit.sh's --setenv.
exec bash "$(dirname "$0")/flash_148_txfix.sh"
