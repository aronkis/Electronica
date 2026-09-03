# Serial console for the two ADALM-Jupiter boards — what is needed (for the operator to attach)

Why: the H-7 "dark flash" class hangs the PS before journald can write; only the console shows it.
Status today: no console on either board (`tron:/dev/ttyUSB1` serves neither; HOSTS.md `ttyACM0` is stale).

## Physical
- Connector: the Jupiter carrier exposes the PS UART0 console on its USB console port (the port the
  HOSTS.md `ttyACM0` entry referred to — a USB-CDC/UART bridge; on Jupiter it is the micro-USB /
  USB-C port labelled UART or CONSOLE next to the Ethernet jack, NOT the USB-C power input). If the
  board revision instead exposes a 3-pin/6-pin UART header, a 3.3 V USB-UART cable (FTDI TTL-232R-3V3
  or CP2102) on GND/TX/RX works the same. Please confirm the label on the board; the settings below
  are the ZynqMP defaults either way.
- Cable: USB-A (host) → micro-USB or USB-C (board) data cable, one per board; both to the SAME lab
  host (nemo or tron — nemo preferred, it runs the units), ideally through a powered hub so a board
  power-cycle cannot drop the host's USB tree.
- Settings: 115200 8N1, no flow control.

## Host side (nemo) — run these once the cables are in
1. Identify each adapter by serial so the mapping survives re-plugs:
   `udevadm info -q property -n /dev/ttyUSB0 | grep -E 'ID_SERIAL|ID_VENDOR|ID_MODEL'` (repeat for
   each new tty that appears). Then `/etc/udev/rules.d/99-jupiter-console.rules`:
   `SUBSYSTEM=="tty", ATTRS{serial}=="<serial-of-148-adapter>", SYMLINK+="jup148"`
   `SUBSYSTEM=="tty", ATTRS{serial}=="<serial-of-146-adapter>", SYMLINK+="jup146"`
   `sudo udevadm control --reload && sudo udevadm trigger`
2. Logger units (user units, survive session exit; one per board):
   `~/.config/systemd/user/console-jup148.service`:
   ```
   [Unit]
   Description=Jupiter 148 console logger
   [Service]
   ExecStart=/bin/sh -c 'stty -F /dev/jup148 115200 raw -echo; exec socat -u /dev/jup148,raw,echo=0,b115200 - | while IFS= read -r l; do printf "%s %s\n" "$(date +%%F_%%T.%%3N)" "$l"; done >> /home/tcollins/modem-status/console_148.log'
   Restart=always
   RestartSec=5
   [Install]
   WantedBy=default.target
   ```
   (same for 146 with jup146 / console_146.log). `systemctl --user daemon-reload && systemctl --user
   enable --now console-jup148 console-jup146`. `loginctl enable-linger tcollins` so they run without
   a login session.
3. Verify: `tail -f ~/modem-status/console_148.log` shows the login prompt / kernel messages; a
   power-cycle of the board must show u-boot + kernel boot lines in the file.
4. Then the rails can quote the console: the flash rail's failure path will `tail -50` the console log
   into the flash log (one-line change I will make once the files exist).
