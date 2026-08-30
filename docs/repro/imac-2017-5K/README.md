# 2017 iMac 5K reproduction guide

This directory records reproducible evidence for the dedicated 2017 27-inch
5K iMac display-appliance experiment. A successful build is not a successful
monitor. Results are accepted only when the exact source revision, binaries,
hardware, command, duration, and exit status are recorded together.

## Safety and privacy

- Use a trusted direct Thunderbolt connection. The experimental screen protocol
  on TCP port 54321 is not authenticated or encrypted.
- Do not publish raw `system_profiler` output, `.xcresult` bundles, dSYMs, logs,
  screen captures, window inventories, or photographs with EXIF metadata.
- Replace hostnames and addresses with `<sender>` / `<imac>` and
  `<sender-tb-ip>` / `<imac-tb-ip>`.
- Use key-based SSH with a non-empty account password. Disable Remote Login when
  remote maintenance is no longer needed.
- Install the sender at its final path before granting Screen Recording. An
  ad-hoc rebuild changes its code identity and can require permission again.

## Build

From the repository root:

```sh
./TargetBridge-Sender/scripts/build_targetbridge_sender_app.sh
./TargetBridge-Receiver/scripts/build_targetbridge_5k_receiver_app.sh
```

Verify both bundles before copying them:

```sh
codesign --verify --deep --strict --verbose=2 build/TargetBridge.app
codesign --verify --deep --strict --verbose=2 \
  'build/TargetBridge 5K Receiver.app'
lipo -info build/TargetBridge.app/Contents/MacOS/TargetBridge
lipo -info \
  'build/TargetBridge 5K Receiver.app/Contents/MacOS/TargetBridge5KReceiver'
```

The receiver must include `x86_64`; the 2017 iMac is Intel.

## Component tests

```sh
(
  cd TargetBridge-Sender
  xcodebuild -project TargetBridge.xcodeproj \
    -scheme TBDisplaySender \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath .build/TestDerivedData \
    test
)

(
  cd TargetBridge-Receiver/TBReceiverC
  make test
)
```

Run the exact Retina probe on the sender and record the point and pixel sizes:

```sh
(
  cd TargetBridge-Sender
  mkdir -p .build/Diagnostics
  clang -fobjc-arc -framework AppKit -framework CoreGraphics \
    Diagnostics/probe_virtual_display_hidpi.m \
    -o .build/Diagnostics/probe_virtual_display_hidpi
  ./.build/Diagnostics/probe_virtual_display_hidpi 2560 1440
)
```

The probe also defaults to `2560 1440` when no dimensions are supplied. The
required settled mode is `2560x1440 points -> 5120x2880 pixels`. Merely seeing a
5120 × 2880 capture buffer is not enough.

As a negative control, run the same binary with `5120 2880`. Those values ask
for 5120 × 2880 **logical points**, not a 2560 × 1440 Retina desktop. Record
either the construction failure or the `initial` line to show why a requested-
size or packet-size label alone is not proof. The probe may subsequently find
and switch to the correct generated Retina mode; grade the run only from a
`settled` line with the exact point/pixel pair above:

```sh
TargetBridge-Sender/.build/Diagnostics/probe_virtual_display_hidpi 5120 2880
```

For a bounded changing-content test, compile and run the Retina motion target.
It refuses to select an arbitrary 5K screen: automatic selection requires the
`TB Extend` virtual-display name plus the exact Retina geometry. An explicit
CoreGraphics display ID can be supplied as the second argument when recording
an independently resolved target:

```sh
xcrun clang -fobjc-arc -Wall -Wextra -Werror \
  -framework AppKit -framework CoreGraphics -framework QuartzCore \
  TargetBridge-Sender/Diagnostics/probe_virtual_display_animation.m \
  -o TargetBridge-Sender/.build/Diagnostics/probe_virtual_display_animation
TargetBridge-Sender/.build/Diagnostics/probe_virtual_display_animation 60
# Explicit alternative: .../probe_virtual_display_animation 60 <display-id>
```

The target draws a moving one-physical-pixel grid, color bars, and fine text,
then exits. It writes no frame files; its final line reports the requested
duration, delivered timer ticks, and `filesWritten=0`.

## Profile names and frame rates

`Work 5K` selects the normal `native5k` preset: 5120 × 2880 at 48 FPS. The
lossless 60 FPS acceptance experiment instead uses the separate
`native5k60Experimental` preset with DPCM explicitly enabled and successfully
negotiated. Do not treat selecting `Work 5K` as evidence of a 60 FPS run.

## Cursor acceptance mode

Leave TargetBridge's optional **Large Cursor** toggle off for this appliance
build. The accepted path captures the native macOS cursor inside the Retina
frame and hides the iMac's otherwise-duplicated local cursor only while a
display session is active. That preserves native arrow, I-beam, hand, resize,
and temporary system cursor shapes. The dedicated DPCM receiver does not yet
re-present packet `0x32` over a cached DPCM texture, so the optional custom
large-cursor overlay is explicitly outside this release rather than silently
claimed as working. The appliance launch agent explicitly supplies
`--large-cursor 0`, so a stale GUI preference cannot accidentally select that
unsupported overlay after login or reconnect.

## Install and rollback

Install the sender at its final path on the MacBook before granting Screen
Recording:

```sh
mkdir -p "$HOME/Applications"
test ! -e "$HOME/Applications/TargetBridge 5K Sender.app"
ditto build/TargetBridge.app \
  "$HOME/Applications/TargetBridge 5K Sender.app"
./TargetBridge-Sender/scripts/install_targetbridge_5k_sender_launch_agent.sh \
  "$HOME/Applications/TargetBridge 5K Sender.app"
```

For a first receiver install, package the universal app on the MacBook and copy
both it and the dedicated installer to the iMac. Replace `<imac-ssh>` only with
the already-verified SSH target; do not publish that value in results:

```sh
receiver_stage="$(mktemp -d /tmp/targetbridge-5k-receiver.XXXXXX)"
receiver_archive="$receiver_stage/targetbridge-5k-receiver.zip"
ditto -c -k --sequesterRsrc --keepParent \
  'build/TargetBridge 5K Receiver.app' "$receiver_archive"
scp "$receiver_archive" \
  TargetBridge-Receiver/scripts/install_targetbridge_5k_receiver_launch_agent.sh \
  '<imac-ssh>:/tmp/'
ssh '<imac-ssh>' /bin/zsh <<'REMOTE'
set -euo pipefail
mkdir -p "$HOME/Applications"
test ! -e "$HOME/Applications/TargetBridge 5K Receiver.app"
ditto -x -k /tmp/targetbridge-5k-receiver.zip "$HOME/Applications"
/tmp/install_targetbridge_5k_receiver_launch_agent.sh \
  "$HOME/Applications/TargetBridge 5K Receiver.app"
unlink /tmp/targetbridge-5k-receiver.zip
unlink /tmp/install_targetbridge_5k_receiver_launch_agent.sh
REMOTE
unlink "$receiver_archive"
rmdir "$receiver_stage"
```

Production upgrades should stage a uniquely named bundle, verify it, move the
prior bundle to a recoverable rollback location, and then atomically swap the
stable path.

Verify the installed executables match the reviewed build artifacts:

```sh
shasum -a 256 \
  'build/TargetBridge.app/Contents/MacOS/TargetBridge' \
  "$HOME/Applications/TargetBridge 5K Sender.app/Contents/MacOS/TargetBridge"
ssh '<imac-ssh>' \
  '/usr/bin/shasum -a 256 "$HOME/Applications/TargetBridge 5K Receiver.app/Contents/MacOS/TargetBridge5KReceiver"'
```

The installers add per-user launchd jobs; they do not install a kernel
extension, display driver, firmware, or system-wide daemon. The current personal
build is ad-hoc signed, so another Mac still needs one explicit Screen Recording
grant at the sender's final path. A Developer ID/notarized release is separate
distribution work, not hidden behind the word “automatic.”

Rollback:

```sh
./TargetBridge-Sender/scripts/uninstall_targetbridge_5k_sender_launch_agent.sh
ssh '<imac-ssh>' /bin/zsh -s < \
  TargetBridge-Receiver/scripts/uninstall_targetbridge_5k_receiver_launch_agent.sh
```

The second command streams the checked-in receiver uninstaller to the iMac; it
does not assume the repository or a leftover installer exists there. Confirm
that no process is listening on port 54321 afterward. The uninstall scripts
leave the app bundles in place so deletion is a separate, recoverable decision.

## Graceful receiver restart and cursor acceptance

The receiver handles `SIGTERM` and `SIGINT` through dispatch signal sources.
The signal closes session admission, wakes an idle listener through a private
pipe, shuts down an active peer socket, and lets the transport worker reach the
same cleanup epilogue used by a normal disconnect. Do not accept the lifecycle
gate from process disappearance alone: the iMac cursor hide count, power
assertions, and bounded Metal teardown must also complete.

With a display session active and the iMac's local cursor known to be hidden,
run this on the iMac from an interactive Terminal. It unloads only the per-user
receiver job and leaves the app bundle and plist in place:

```sh
label='com.targetbridge.receiver5k'
domain="gui/$(id -u)"
plist="$HOME/Library/LaunchAgents/$label.plist"
before_pid="$(pgrep -f '/TargetBridge 5K Receiver.app/Contents/MacOS/TargetBridge5KReceiver$')"
time launchctl bootout "$domain" "$plist"
! kill -0 "$before_pid" 2>/dev/null
! lsof -nP -iTCP:54321 -sTCP:LISTEN
log show --last 2m --style compact \
  --predicate 'subsystem == "com.targetbridge.receiver5k"' | \
  grep -E 'shutdown=(requested|complete)|localCursor=restored'
```

Acceptance requires a `shutdown=requested` line, either the session or shutdown
`localCursor=restored` line, and `shutdown=complete ... power=released
metal=teardown-complete`. On the physical iMac, move its local pointer and
confirm it is visible immediately after `bootout`; one extra hidden-cursor
count is a failure.
The command must finish well inside launchd's termination grace period. The
renderer drain itself is bounded to about two seconds; record the observed wall
time rather than claiming an exact universal total.

Then prove reinstall works even when an old launchd disabled override exists:

```sh
launchctl disable "$domain/$label"
launchctl print-disabled "$domain" | grep '"com.targetbridge.receiver5k" => true'
./TargetBridge-Receiver/scripts/install_targetbridge_5k_receiver_launch_agent.sh \
  "$HOME/Applications/TargetBridge 5K Receiver.app"
! launchctl print-disabled "$domain" | \
  grep '"com.targetbridge.receiver5k" => true'
launchctl print "$domain/$label" | grep -E 'state = running|pid = '
lsof -nP -iTCP:54321 -sTCP:LISTEN
```

The installer intentionally runs `launchctl enable` before `bootstrap`; the
component suite checks that ordering so a prior `launchctl disable` cannot make
a successful-looking reinstall leave the receiver inactive. Finally reconnect
the sender and repeat cursor movement, clicking, and disconnect once.

## Hardware acceptance sequence

1. Verify true Thunderbolt Bridge, not Wi-Fi, Ethernet, or USB fallback.
2. Verify the receiver advertises `supportsDPCM=1`.
3. Verify the sender activates 2560 × 1440 points / 5120 × 2880 pixels before
   capture begins.
4. Verify the first captured frame, DPCM frame, and receiver drawable are all
   5120 × 2880.
5. Verify the receiver reports Display P3 for the DPCM layer.
6. Record FPS, p50/p95/p99 arrival gaps, GPU time, queue drops, malformed
   frames, and renderer failures.
7. Confirm fine black text, colored text, single-pixel grids, gradients, cursor,
   clicking, dragging, and scrolling on the physical iMac.
8. Repeat with the Dell display and power connection present.
9. Repeat unplug/replug, sender restart, receiver restart, and sleep/wake.
10. Run a ten-minute initial soak and a one-hour sustained soak.

## Resource acceptance

Record sender and receiver RSS, virtual memory, CPU, open file descriptors,
network throughput, and application-support/log directory sizes at start and
at fixed intervals. Memory and descriptor counts must plateau; logs must remain
bounded. Record MacBook battery state and thermal-pressure observations, but do
not infer energy use from a single instantaneous CPU sample.

The bounded foreground collector records RSS, VSZ (virtual address-space size),
process and storage state, plus the power, battery, and thermal state that macOS
exposes without root. Connect
to the iMac once manually so its host key is known, then run this from the
repository root with an unused output path:

```sh
./docs/repro/imac-2017-5K/scripts/collect_resources.zsh \
  --ssh-host '<imac-user>@<imac-tb-ip>' \
  --duration 600 \
  --interval 10 \
  --output "$PWD/targetbridge-resources-10m.tsv"
```

The SSH target is required for the connection but is deliberately omitted from
the TSV. The script requires key-based, non-interactive SSH; samples the
installed `TargetBridge` and `TargetBridge5KReceiver` processes; refuses to
overwrite an existing result; and removes its temporary file if interrupted.
It runs no background process and has hard limits of 24 hours and 10,001
samples per machine. It reads file sizes but never reads application log
contents or screen frames. Store results outside the repository until they have
been reviewed and sanitized.

Interpret the TSV as a time series, not as a one-line benchmark:

- `process_status` must remain `running`. A PID change is evidence of a restart;
  `missing`, `multiple`, `vanished`, `ssh_error`, or `ssh_protocol_error` fails
  the run. Process discovery matches the executable inside the documented
  installed app bundle, not merely a same-named development binary.
- Compare the early steady-state window with the final window. RSS, VSZ, thread, and
  numeric-FD counts should settle into a bounded band instead of increasing
  monotonically. Investigate any sustained rise; this harness intentionally
  does not invent universal memory or CPU thresholds.
- `app_kib` should remain constant and nonzero. `app_support_kib` and `log_kib` must plateau
  within their documented rotation bounds. A growing directory fails the
  storage-safety gate even when the display still looks correct.
- Review CPU as a distribution over the whole run. Correlate battery percentage,
  battery state, power source, and the available `pmset` thermal notes with the
  same timestamps. A single CPU or battery sample is not an energy measurement.
- This collector does not measure frame cadence, latency, GPU time, or network
  throughput. Record those separately from bounded application counters and
  the visual acceptance sequence; do not infer them from CPU or RSS.

The DPCM hot path writes no frames to disk. The sender input-debug log is capped
at 1 MiB plus one rotated 1 MiB generation. The receiver launch agent does not
append stdout/stderr to permanent files.

## Current results

See [`results/2026-08-29-component-tests.md`](results/2026-08-29-component-tests.md).
The incremental physical-iMac evidence is recorded separately in
[`results/2026-08-29-imac-runtime-acceptance.md`](results/2026-08-29-imac-runtime-acceptance.md).
Neither file substitutes for the pending active 5K60 and one-hour-soak result.
