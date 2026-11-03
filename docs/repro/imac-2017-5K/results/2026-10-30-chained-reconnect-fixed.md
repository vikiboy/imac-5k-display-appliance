# Chained reconnect fixed — 2026-10-26 to 2026-10-30

Resolves the open questions in
[2026-10-13](2026-10-13-thunderbolt-negotiation-failure.md) and
[2026-10-19](2026-10-19-receiver-presentation-timeout.md) for the required
topology: MacBook → Studio Display → iMac18,3.

## Cause 1: the iMac port settles in USB mode

Each connect ends in one of two states, read from the iMac's TI USB-PD
controllers through `AppleHPMLib`:

| State | PD status | Data status | Meaning |
|---|---|---|---|
| Good | `0x1000b21d` | `0x16110003` | iMac sink/UFP, Thunderbolt bit set |
| Bad | `0x108280ff` | `0x00000073` | iMac source/DFP, USB 2/3 only |

The bad state follows a MacBook unplug: the Studio Display's downstream port
renegotiates with the iMac alone and lands in USB. Nothing restarts
negotiation on MacBook replug, which is why only a physical replug helped.
A direct MacBook–iMac connection can also land in USB (the iMac then
enumerates the MacBook's `05ac:1905` USB network gadget), so the Studio Display
is not the cause.

Fix: [`tools/imac-tblink`](../../../../tools/imac-tblink/README.md), a root
LaunchDaemon on the iMac. When a cable is present but Thunderbolt stays down
for 5 s it sends the controller's `Gaid` reset (an electronic replug);
Thunderbolt returns in about 3 s. Role-swap commands (`SWUF`, `SWSk`) are
declined by the partner and `HRST` is unsupported.

Fixed bridge addresses (MacBook `169.254.10.1`, iMac `169.254.10.2`,
`255.255.0.0`) remove the ~19 s DHCP wait while staying link-local, as both
apps require.

## Cause 2: receiver wedged by a stale power-gate failure

On 2026-10-26 18:35 a session ended with `display-power-gate-failed` while the
iMac panel was going to sleep. That flag is cleared only inside a live session,
so every later session closed at `initial-lifecycle-state` before profile and
the sender looped on `pre-profile reconnect budget exhausted`. The failure was
logged only to stderr, so it was invisible in the unified log.

Fix: in serve mode the receiver now exits (code 74) on a stale power-gate
failure and launchd starts a fresh process. The presentation-timeout change
from 2026-10-26 follows the same restart pattern.

Note: `launchctl kickstart -k` restarts only the `open -W` wrapper; the app
process must be stopped to restart the receiver by hand.

## Cause 3: lock screen

The iMac screen lock was set to immediate, so after the panel slept the
session sat behind the lock screen. Reinstalled with
`TB_APPLIANCE_DISABLE_SCREEN_LOCK=1` and enabled automatic login for the
appliance account.

## Acceptance

| Test | Result |
|---|---|
| MacBook unplug/replug at the Studio Display, several rounds | Display live ~15 s after replug, no manual action |
| Port found in USB mode on arrival | One automatic reset, Thunderbolt restored |
| iMac full restart (`shutdown -r now`) | Auto-login, no lock, display live ~55 s later |

## Follow-up 2026-11-03

The receiver wedged again after `display-power-gate-failed` on 2026-10-30
16:41, but this time sessions were refused before the
`initial-lifecycle-state` check, so the targeted exit never ran. Several
setup paths between HELLO and profile retry in process without logging.
The receiver now counts accepted sessions that never reach profile-sent and
exits after more than 5 in a row (reset on every successful start), so any
such wedge recovers through launchd within one sender retry cycle.
