# Evidence ledgers

These are the investigation ledgers the documentation cites. They are moved verbatim
from `two_jup/` and are not edited after the move; when a doc page and a ledger
disagree, the ledger wins (it carries the command, the sample count, and the run
directory). Paths inside a ledger refer to the tree at tag
`archive/pre-cleanup-2026-09-09`, where the run directories, capture data, and
one-off scripts they name still exist.

| Ledger | What it establishes |
|---|---|
| `RXFIX_STATE.md`, `TXFIX_STATE.md` | Forward comb root cause and the R4B/R4D/R1 ring fixes, and the TX-side beat fix; PER credited both legs |
| `comb/*.md` (44 files) | 2026-09 comb campaign: BS census, PAD, WHITEN, SRO sim gates, CRC regression 09-07, morning reports 09-08/09-09 |
| `rxfix/W1_REGMAP.md` | W1/R4D/R4E/BS witness-word register map (field-order correction) |
| `ERROR_TAXONOMY.md` | Loss classes 1-4 with silicon signatures |
| `WEDGE_ROOT_CAUSE.md`, `WEDGE_JUNK_CLASS.md` | Acquisition wedge dissection |
| `LOSS_LEDGER.md`, `KNOWN_HOLES.md` | Running loss accounting and open holes |
| `FLOAT_FIXED_CAMPAIGN.md`, `FLOAT_GAP_BUDGET.md`, `TICK_FIX_SIM.md` | Float-vs-fixed parity and the BBDC tick |
| `SINGLES_CAMPAIGN.md`, `SINGLES_REPLAY.md`, `FWD_SINGLES_ROOT_CAUSE.md`, `PAIR_RECURRENCE.md` | Forward singles/doubles campaign |
| `DMAC_IDENTIFIED.md`, `FIFO_ECHO_TEST.md`, `LAYERB_RUN_RESULT.md`, `HARNESS_AB.md` | Delivery-plane exoneration |
| `RIG_NOPING_FAULT.md`, `BRINGUP_SEQUENCER.md` | Rig operating hazards and the bring-up order |
| `HANDOFF_2026081[235].md`, `ESCALATION_ADI.md`, `SLX_RECONCILE.md`, `SKID_BUILD.md` | Handoffs, vendor escalation, model reconciliation, skid build |
| `FRAMESTAT_NOTES.md` | The per-frame RX telemetry contract: record layout, the 0x1C0-0x1DC register block, and the non-popping read/pop protocol. Cited by `docs/byte-plane.rst` as the frame-status contract |
| `FIFO_DRIFT_FINDING.md` | Bit Packetizer "Data Bits FIFO" slow drift: pre-existing and sps-independent, not introduced by the sps=4 rung |
| `RX_STALL_MAP.md` | Every path that can gate or mute packet delivery on f1536/sps=4, mapped against the generated netlist — the reference for delivery-freeze episodes |

The last three were moved from `jupiter_240k5_byte/` (now `modem/`) on 2026-09-09
rather than from `two_jup/`; each carries the same provenance line at its head.

