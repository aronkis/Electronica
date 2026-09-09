#!/bin/bash
# fake_anyssh_seqbist.sh HOST CMD -- canned register model for seqbist_run.sh
# real-mode (DRY=0) unit tests, driven entirely by env vars (no network).
# FAKE_TGEN_RX_CTRL: value returned for a bare `$DM 0x9D410000` read.
CMD="$2"
case "$CMD" in
  *'$DM 0x9D410000'*)
    # seqbist_run.sh's check_tgen_rx_disabled does: v=$($W "$BRD" "$DM; \$DM 0x9D410000")
    echo "${FAKE_TGEN_RX_CTRL:-0}"
    ;;
  *)
    : ;;
esac
