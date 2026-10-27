# imac-tblink: automatic Thunderbolt recovery on the 2017 iMac

## Problem

The MacBook → Studio Display → iMac18,3 chain depends on the iMac's USB-C
port negotiating **Thunderbolt** mode. When the MacBook is unplugged, the
Studio Display's downstream port renegotiates with the iMac. The iMac then
ends up as USB host/power source in plain USB 2/3 mode (PD status
`0x108280ff`, data status `0x00000073`, Thunderbolt bit 16 clear). When the
MacBook returns, nothing restarts the negotiation, so Thunderbolt Bridge,
TargetBridge and the 5K display never come back. A physical replug fixes it
because it restarts USB-PD negotiation.

Diagnosed 2026-10-26 from the iMac kernel log (`IOThunderboltFamily`
plug events, an `05ac:1905` USB enumeration of the MacBook) and from PD
controller registers read via `AppleHPMLib`.

## Fix

`hpmctl watch` runs as a root LaunchDaemon on the iMac. Every 2 s it reads
each port's TI PD controller (Status `0x1A`, Data Status `0x5F`) through
Apple's `AppleHPMLib` plugin. If a cable is present but Thunderbolt is down
for 5 s, it sends the controller's `Gaid` reset command, an electronic replug.
Thunderbolt returns within about 3 s. It allows 5 resets per plug-in with
backoff, then waits for an unplug, so a USB-only device in the port is never
reset in a loop.

Verified 2026-10-26 over several rounds: MacBook unplug/replug recovers to a
live 5K display in about 15 s with no manual action (replug, then the reset
4 s later, Thunderbolt 7 s later, network and display 4 s after that). Before
this fix it never recovered.

Not working: `SWUF` and `SWSk` (role swaps) are declined by the Studio
Display, and `HRST` returns `!CMD` on Apple's firmware.

## Related configuration

- Thunderbolt Bridge uses fixed link-local addresses (MacBook
  `169.254.10.1`, iMac `169.254.10.2`, mask `255.255.0.0`). This skips the
  ~19 s DHCP timeout. The addresses stay in 169.254/16 because the sender and
  receiver only accept link-local peers on `bridge0`.
- iMac: `pmset -a sleep 0 standby 0 autopoweroff 0 powernap 0`. The display
  may sleep; the system may not.

## Build and install (on any Mac, then copy to the iMac)

```sh
clang -Wall -arch x86_64 -mmacosx-version-min=13.0 \
  -framework IOKit -framework CoreFoundation -o hpmctl hpmctl.c
codesign -s - -f hpmctl
# on the iMac:
sudo install -o root -g wheel -m 755 hpmctl /usr/local/libexec/imac5k-tblinkd
sudo install -o root -g wheel -m 644 com.vikiboy.imac5k.tblink.plist /Library/LaunchDaemons/
sudo launchctl bootstrap system /Library/LaunchDaemons/com.vikiboy.imac5k.tblink.plist
```

Manual use: `sudo hpmctl status`, `sudo hpmctl cmd 0 Gaid`.
Log: `/var/log/imac5k-tblink.log` (state changes only).

`AppleHPMLib.h` comes from osy's ThunderboltPatcher via AsahiLinux/macvdmtool
(Apache-2.0).
