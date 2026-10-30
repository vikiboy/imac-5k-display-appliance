# Presentation-timeout recovery change — 2026-10-26

## Change

`benchmark_targetbridge_raw_receiver.m` now marks a presentation callback drain
timeout as process-fatal, just as it already does for GPU completion failures
and presentation-accounting violations. Previously, this case logged a failure
but returned to the serve loop with the same renderer and its unresolved
callbacks. Earlier hardware sessions demonstrated a timeout followed by repeated
pre-profile failures until a manual receiver restart.

The changed branch exits through the existing cursor/power/transport cleanup.
The existing per-user KeepAlive LaunchAgent restarts the receiver; its ten-second
throttle limits rapid relaunches. Ordinary disconnects without renderer failure
still return to the waiting state in process. This change adds no polling daemon,
frame buffers, or persistent log files.

## Verification and installation

- Universal Intel/Apple Silicon build passed with warnings treated as errors.
- Existing `make test` receiver suite passed, including codec, native Metal,
  shutdown gate, power ownership, cursor ownership, and lifecycle checks.
- Staged app passed code-signature verification on the iMac.
- Installed at the existing stable receiver path while its LaunchAgent was
  stopped, then re-enabled the existing LaunchAgent.
- Startup accepted the physical 5120×2880 panel and listened on port 54321.
- One old receiver app retained at
  `/Users/admin/Applications/TargetBridge 5K Receiver.before-timeout-recovery.app`.
- Installed executable SHA-256 after local ad-hoc bundle signing:
  `06954a4ffcc1f01788beafc5725926c414beb695e474645a32acf35aa4533647`.

The test suite does not reproduce a missing drawable callback on the Intel
iMac. Actual timeout-triggered relaunch and end-to-end streaming after that
relaunch still require hardware validation. This is a targeted recovery change,
not proof that the original presentation timeout cannot occur.

## Separate unresolved transport failure

During installation, both Thunderbolt bridges remained inactive; Studio Display
and iMac reported no connected downstream Thunderbolt device. The new receiver
cannot restore a physical/firmware link that macOS does not enumerate. The owner
reported a brief visual recovery, but the collected interval has no new receiver
`session=live` event establishing a subsequent working stream. Preserve that
distinction rather than inferring which layer failed from a black screen alone.

## Further transport isolation

Held remote display-idle, system-idle, and system-sleep prevention assertions
for a bounded 45 seconds, with a user-activity wake. Assertions were confirmed
active; neither Thunderbolt Bridge became active and the iMac still detected
no peer. Assertions expired normally. This does not prove power management is
uninvolved, but rules out a simple sustained-awake assertion as a sufficient
repair of the observed state.

MacBook Software Update reported no new software available during this check.
An online first-person report describes a similar USB4-hub/Mac reconnect
failure (USB networking returns while the Thunderbolt router does not):
https://www.reddit.com/r/Thunderbolt/comments/1x1d4db/thunderbolt_networking_works_on_linuxmacbook_with/
It uses a Linux peer and does not establish the cause or a fix for this setup.

Next useful physical comparison: exchange the two existing Thunderbolt cables
between the upstream and downstream segments, retaining the same ports and
topology. This tests cable/endpoint interaction without purchasing hardware.
The test is pending and is not a promised fix; upstream speed may change with
the exchanged cable. Assess device enumeration before streaming performance.
