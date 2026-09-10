> Evidence ledger, moved verbatim from `two_jup/DMAC_IDENTIFIED.md` on 2026-09-09. Relative paths inside refer to the tree at tag `archive/pre-cleanup-2026-09-09`.

# Modem RX DMAC instantiation — IDENTIFIED (2026-08-12, off-hardware search)

The long-standing blocker "modem DMAC instantiation unidentified" is closed.

## The instance

**`rx_byte_dma`**, an ADI `axi_dmac`, instantiated in the MathWorks/ADI
reference-design BD script **outside this repo**:

`/home/tcollins/dev/qpsk_ai/TransceiverToolbox/hdl/vendor/AnalogDevices/vivado/projects/scripts/matlab_processors.tcl`

| line | content |
|---|---|
| 996  | `jupiter_sdr {` — the ZynqMP/Jupiter carrier branch |
| 1026 | whole byte plane gated on the plugin parameter `::byte_dma eq "on"` |
| 1061 | `ad_ip_instance axi_dmac rx_byte_dma`  ← the instantiation |
| 1064 | `ad_ip_parameter rx_byte_dma CONFIG.CYCLIC 0`  ← current value |
| 1062/1063 | `DMA_TYPE_SRC 1` / `DMA_TYPE_DEST 0` — S2MM, matches qpsk_tun's 0x408/0x418/0x428 usage |
| 1100 | `ad_cpu_interconnect 0x9D200000 rx_byte_dma`  ← the address assignment (M_AXI_HPM0_LPD) |

Reached via `build_variant_byte.m` → TransceiverToolbox `setup.m` → HDL Coder plugin
`+AnalogDevices/+jupiter/plugin_rd_rxtx_byte.m` (referenced from
`byte_plumbing_overlay_k5.m:269`), which sets `byte_dma`. Why every in-repo search
dead-ended: the file is not in this git repo. Corroborated in built artifacts: all 21
`jupiter_byte_*_build` trees carry `system_rx_byte_dma_0.xci` with `"CYCLIC": "false"`,
and `system.hwh` maps `BASEVALUE=0x9D200000 INSTANCE=rx_byte_dma`. Siblings:
`0x9D100000 tx_byte_dma`, `0x9D300000 byte_ctrl_gpio`, modem IP at `0x9D000000`.

## The prior cyclic attempt targeted the WRONG IP — do not reuse it

`two_jup/cyclic_dma_patch/system_bd.tcl.patch` and `build_cyclic_image.sh:26` both
patch/gate on **`axi_adrv9001_rx1_dma`** (the ADI IQ-capture DMA at `0x44A30000`),
not `rx_byte_dma`. That misidentification explains commit `e6fa5f0`'s recorded outcome
("built bitstream broke byte delivery + forward air, rolled back"): the modem DMAC was
never touched, and a cyclic-latched rx1_dma streams S2MM forever onto the HPC0
interconnect it **shares** with `rx_byte_dma/m_dest_axi` (`matlab_processors.tcl:1101`
vs `system_bd.tcl:628`) — a plausible (unverified) mechanism for the breakage.

## Setting CYCLIC — safe to bake, opt-in at runtime, but know the caveat

- In-repo hook: `jupiter_240k5_byte/complete_byte_t8.tcl:76` already asserts
  `rx_byte_dma` exists in the BD; add
  `set_property CONFIG.CYCLIC 1 [get_bd_cells rx_byte_dma]` after that guard.
  `build_cyclic_image.sh:26`'s grep guard (currently keyed on the `$_rx1dma` line)
  must be re-keyed.
- The register path is permissive (`up_dma_cyclic <= up_wdata[0] & DMA_CYCLIC`), so a
  CYCLIC-capable bitstream **runs the current host unchanged** until FLAGS bit0 is set.
- **When FLAGS bit0 IS set:** with `DMA_SG_TRANSFER=0` (confirmed false in the built
  xci), cyclic mode ties `up_sot/up_eot` to 0 — `0x428 TRANSFER_DONE` never sets and
  the UIO EOT IRQ goes dead. The host must switch to content-based completion
  (`cyclic_dma_patch/HOST_RING_REWRITE.md` §3 remains valid; only its target IP name
  was wrong).

## Consequence for the batched instrument image (Track H)

Cyclic RIDES ALONG: include `CONFIG.CYCLIC 1` on `rx_byte_dma` in the same image as
the framestat checkpoint-1 overlay. Zero behaviour change until opted in, and it
removes the need for a second flash when the ring-rewrite experiment runs.
