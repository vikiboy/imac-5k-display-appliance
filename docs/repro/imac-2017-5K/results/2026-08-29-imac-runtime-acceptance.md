# 2017 iMac runtime acceptance — 2026-08-29

This is an incremental hardware record for receiver source commit
`fa8b8ce6272dcd851d4d7ac152d910eb323e3551`. It does not yet claim the final
active-stream or one-hour-soak gates.

## Installed receiver

- Hardware: 2017 27-inch iMac, Radeon Pro 575
- macOS: 13.7.8 (22H730)
- Installed executable SHA-256:
  `0fa1d1a323ddaa7c8afcb3432baa3e79dd97dfd8e14da28f9c92eb70b33b097e`
- Launch agent: `com.targetbridge.receiver5k`
- Listener: TCP 54321

The receiver's physical gate accepted display ID `69986024` at an exact
5120×2880 raster and 2× backing scale. WindowServer reported the appliance
window on-screen at 2560×1440 points, which maps exactly to the physical 5K
Retina framebuffer. `system_profiler` independently reported:

- Built-In Retina LCD;
- Retina 5K (5120×2880);
- 30-bit color (ARGB2101010);
- online, internal connection, mirror off.

## Start while the panel is asleep

The panel was deliberately sent to display sleep, then the receiver launch
agent was restarted with `launchctl kickstart -k` while the panel was asleep.

| Observation | Result |
|---|---:|
| PID before restart | 19642 |
| PID after restart | 20135 |
| Launch count | 2 |
| Last exit code | 0 |
| Physical 5K gate after restart | Accepted |
| TCP 54321 after restart | Listening |
| Appliance window after restart | On-screen, 2560×1440 points |
| Duplicate AppKit launch/menu exception | None |
| Inactive-order/key-window warning | None |

This reproduces the former failure condition without reproducing its launchd
restart loop. The new process acquired its power lifecycle, woke and
re-enumerated the panel, validated native 5K geometry, and became ready in one
launch.

## Idle resources

The separate raw sample
[`2026-08-29-idle-resource-baseline.tsv`](2026-08-29-idle-resource-baseline.tsv)
contains seven ten-second-interval observations. Receiver CPU remained 0.0%,
RSS remained exactly 16,336 KiB, open descriptors remained 11, and application
support/log storage remained zero throughout the one-minute baseline.

## Still required

- one final Screen Recording grant for the immutable sender binary;
- recorded native-5K DPCM session and exact sender virtual-display geometry;
- visual text/grid/gradient/cursor acceptance with the Dell attached;
- unplug/replug and complete sender/receiver sleep-wake recovery;
- ten-minute initial and one-hour active resource soaks.
