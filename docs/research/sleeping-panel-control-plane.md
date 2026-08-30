# Research note: listener-first recovery for a sleeping or locked iMac

Status: **implemented in installed version 0.9/build 19; source sleep/wake and
physical cable reconnect passed**. Build 18 exposed the edge. Build 19 adds a listener-first wake
broker and a bounded sender handoff without claiming that an unattended locked
macOS session can or should be bypassed.

## The observed edge

The build-18 iMac receiver restarted while macOS already reported the console
session locked and the built-in 5120 x 2880 panel online but asleep. The
receiver correctly refused to expose pixels or request display power. Its
startup order also waited for a drawable `NSScreen` before creating port 54321,
however,
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

Build 18 coupled them. The robust analogy is a network service
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

## Implemented build-19 sequence

1. A lightweight listener and conservative Bonjour advertisement start before
   a drawable `NSScreen` or Metal renderer exists.
2. The shared pre-session classifier consumes discovery and throughput probes
   without waking anything. Promotion requires both endpoints to be link-local
   and the receiver endpoint to be the current `bridge0` address.
3. Only a valid display HELLO issues one public remote-user-activity wake. It
   does not yet hold `PreventUserIdleDisplaySleep`, and the wake is bounded to
   eight seconds.
4. The wake-only socket closes. The Sender's internal pre-profile policy retries
   the same manual or automatic connection at 0.25, 0.5, 1, 2, 2, and 2
   seconds. Ordinary initial dial failures do not arm this policy, so Connect
   does not become an unbounded background loop.
5. Once AppKit reports the exact awake native 5K Retina surface, the broker
   releases its temporary wake, closes its listener/Bonjour state, and the full
   renderer/listener starts. The retry then receives the real display profile.
6. The full session owns its one-shot wake and display-awake assertion. The
   existing lifecycle epochs pause capture, codec, GPU, audio, and frame traffic
   whenever either source or receiver surface is unavailable, and the opaque
   cover stays up until a fresh current-generation frame is presented.

The startup SIGTERM/SIGINT handler is deliberately process-wide and remains the
single signal owner through the broker, renderer construction, and activation
of both dispatch signal sources. A latched startup request is then replayed
through the normal shutdown gate. This avoids a thread-local mask handoff that
could lose a process-directed signal on an AppKit or Bonjour worker.

An unconditional wake during every receiver restart is intentionally rejected:
it would turn on the iMac when no MacBook display session exists.

## Proof completed without waking the sleeping owner

- sender suite: 141 tests, including six finite-retry state-machine tests and a
  negotiated-profile stability-backoff gate;
- receiver suite: parser, Metal, cursor, shutdown, pre-session, display-
  lifecycle, and power-lifecycle tests all pass;
- repeated power tests prove no overlap across 25 reconnect cycles and retain
  failed IOKit IDs until release succeeds;
- structural contracts prove probes cannot promote wake, both bridge endpoints
  are validated, the wake and packet deadlines are bounded, capture resources
  are not allocated during retry, and automation cannot cancel or duplicate the
  internal handoff; and
- universal `arm64`/`x86_64` Release builds and strict bundle signatures pass.

## Physical proof and remaining broader-release work

- passed on the exact setup: source display sleep/wake paused and restored the
  extended desktop after a fresh frame;
- passed on the exact setup: physical Thunderbolt unplug/replug briefly entered
  the paused state and restored one stream/display without relaunch or consent;
- passed on the exact setup: one cursor and normal clicking/dragging after an
  ordinary physical unlock;
- still required for a broader release: unlocked + panel asleep + receiver restart: listener/Bonjour remain ready;
  one valid HELLO causes one wake and a fresh-epoch resume;
- no HELLO and all discovery probes: zero wake/display assertions;
- locked + HELLO: only Apple's secure UI is visible, `surface=false`, zero
  frame admission, zero cursor hide, and zero display-sleep assertion;
- normal unlock resumes only after a fresh current-generation frame;
- fast-user-switch and inactive-session launch stay fail-closed;
- 25 sleep/wake/reconnect cycles balance every cursor and power assertion;
- legacy peers are closed/retried without partially consuming a frame; and
- listener, descriptor, thread, RAM, and storage counts remain bounded.

An already locked iMac still requires one ordinary physical unlock. A black
screen with its local cursor is Apple's secure login layer, not the receiver's
frame. Build 19 is accepted for the owner's personal display appliance; the
remaining cycle-count and one-hour resource gates prevent a general production
claim.
