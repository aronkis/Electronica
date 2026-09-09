# Board 148 boot.scr NOTE (do not lose on restores)

Board 10.0.0.148's U-Boot environment has NO persistent `ethaddr` — its MAC
comes from `/boot/boot.scr`. Any boot.scr rebuild/restore MUST keep:

```
setenv ethaddr 00:04:9f:00:00:02
```

or the board comes up with a random MAC and the DHCP reservation for
10.0.0.148 no longer matches (board "disappears" from its address).

Campaign boot.scr bootargs (as of 2026-07-28, R2 rung; boot.scr wins over
/boot/uEnv.txt on these boards — see UIO_DT_RECON.md):

```
setenv bootargs console=ttyPS0,115200 root=/dev/mmcblk0p2 rw earlycon rootfstype=ext4 rootwait clk_ignore_unused cpuidle.off=1 uio_pdrv_genirq.of_id=generic-uio
```

`uio_pdrv_genirq.of_id=generic-uio` is REQUIRED for the qpsk UIO nodes
(uio0-2) to bind — it is now explicit in bootargs instead of relying on the
previously-unexplained append (UIO_DT_RECON.md:40).

Rebuild recipe (any host with u-boot mkimage; source = boot148.cmd pattern):
```
mkimage -A arm64 -O linux -T script -C none -n "campaign boot 148 + ethaddr" \
        -d boot148.cmd boot.scr
```
Rollback banked on the board: /boot/boot.scr.pre-r2 (pre-campaign-args copy).
Board 146 uses the stock "Boot script for jupiter_sdr" boot.scr (no ethaddr
needed — its MAC is persistent).
