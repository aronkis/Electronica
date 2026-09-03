# XVC server (debug_bridge over /dev/mem)

Board-side Xilinx Virtual Cable v1.0 daemon for an FPGA image carrying a
debug_bridge IP in "AXI to BSCAN" (XVC) mode. No kernel module needed.

## On the board (build + run)
    make xvc_server            # plain on-board gcc, libc only
    sudo ./xvc_server 0xA0010000 2542   # <bridge addr from the .xsa/dt>, port

## From the LAN host (Vivado Tcl console)
    open_hw_manager; connect_hw_server; open_hw_target -xvc_url BOARD_IP:2542

Then refresh the device and add the ILA/VIO probes file as usual.

## Caveats
- Uses /dev/mem mmap: needs root, and a kernel without CONFIG_STRICT_DEVMEM
  blocking the range (ADI kernels allow it for fabric addresses).
- The bridge address is baked at Vivado build time -- pass the real one; a
  wrong address hangs the shift poll (100 ms timeout per word, logged).
