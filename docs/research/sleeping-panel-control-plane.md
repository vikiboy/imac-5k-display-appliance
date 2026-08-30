# Research note: listener-first recovery for a sleeping or locked iMac

Status: **researched, not implemented in build 18**. This note records a real
restart edge without implying that the installed appliance already solves it.

## The observed edge

The iMac receiver restarted while macOS already reported the console session
locked and the built-in 5120 x 2880 panel online but asleep. The receiver
correctly refused to expose pixels or request display power. Its current startup
order also waits for a drawable `NSScreen` before creating port 54321, however,
so the sender cannot establish the control connection that could otherwise
remain paused until a normal unlock.

This is not the cause of ordinary idle display sleep after the dedicated
appliance has been unlocked: the reversible appliance configuration already
sets the iMac screen lock to `off`. It matters after an already-existing lock,
login/reboot, or a receiver restart while no drawable surface is available.

## Useful abstraction

The monitor has two different planes:

- the **control plane** discovers the receiver, authenticates the direct
  Thunderbolt Bridge path, exchanges capabilities and lifecycle epochs, and
  can remain alive without pixels;
- the **surface plane** owns the iMac window, display-awake assertion, cursor
  suppression, Metal renderer, and fresh-frame reveal.

The current startup path couples them. The robust analogy is a network service
whose control socket remains available while an expensive worker is suspended:
accept control first, then admit work only when the resource and security gates
are open.

## Primary API evidence

- Apple documents that `CGGetOnlineDisplayList` includes displays that are
  active, mirrored, **or sleeping**. It can identify the built-in panel before
  an `NSScreen` is drawable.
  [CGGetOnlineDisplayList](https://developer.apple.com/documentation/coregraphics/cggetonlinedisplaylist(_:_:_:))
- Apple documents `CGDisplayIsAsleep` separately. Display sleep must therefore
  be modeled independently from console-session eligibility.
  [CGDisplayIsAsleep](https://developer.apple.com/documentation/coregraphics/cgdisplayisasleep(_:))
- AppKit publishes session-resign notifications and delivers one during launch
  into an inactive session. Lifecycle observers must exist before the app
  completes launch.
  [NSWorkspace sessionDidResignActiveNotification](https://developer.apple.com/documentation/appkit/nsworkspace/sessiondidresignactivenotification)
- A normal window does not become visible over loginwindow by default. The
  appliance must never opt into `canBecomeVisibleWithoutLogin`.
  [NSWindow canBecomeVisibleWithoutLogin](https://developer.apple.com/documentation/appkit/nswindow/canbecomevisiblewithoutlogin)
- `IOPMAssertionDeclareUserActivity` is the public one-shot remote-display wake
  mechanism already used by the receiver's bounded power lifecycle.
  [IOKit power assertions](https://developer.apple.com/library/archive/qa/qa1340/_index.html)

## Candidate sequence

1. Install AppKit/session observers, create the TCP listener, and publish
   Bonjour before requiring a drawable `NSScreen`.
2. Reject non-link-local peers and consume discovery/path probes without waking
   the panel, as the current pre-session classifier already does.
3. Only after a valid Thunderbolt Bridge HELLO, issue one user-activity wake.
   Do not yet hold `PreventUserIdleDisplaySleep`.
4. Send the display profile plus `receiverSurface.available=false` with a new
   epoch. A lifecycle-capable sender then pauses capture, codec, GPU, audio, and
   frame transport while keeping the virtual display arrangement alive.
5. After ordinary session activation and screen wake, acquire the drawable
   native 5K panel on the main thread, create/rebind the window and renderer,
   hold the display assertion, and publish `surface=true` with a new epoch.
6. Keep the black cover until one fresh frame from that exact generation is
   genuinely presented. Any lock, sleep, source sleep, reconnect, parser/GPU
   failure, or stale epoch returns to `surface=false`.

An unconditional wake during every receiver restart is intentionally rejected:
it would turn on the iMac when no MacBook display session exists.

## Required proof before shipping

- unlocked + panel asleep + receiver restart: listener/Bonjour remain ready;
  one valid HELLO causes one wake and a fresh-epoch resume;
- no HELLO and all discovery probes: zero wake/display assertions;
- locked + HELLO: only Apple's secure UI is visible, `surface=false`, zero
  frame admission, zero cursor hide, and zero display-sleep assertion;
- normal unlock resumes only after a fresh current-generation frame;
- fast-user-switch and inactive-session launch stay fail-closed;
- 25 sleep/wake/reconnect cycles balance every cursor and power assertion;
- legacy peers are closed/retried without partially consuming a frame; and
- listener, descriptor, thread, RAM, and storage counts remain bounded.

Until those gates pass on the exact 2017 iMac, listener-first recovery remains a
documented hardening candidate—not a production claim.
