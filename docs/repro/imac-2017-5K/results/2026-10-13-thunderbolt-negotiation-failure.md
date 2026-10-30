# Recurring Thunderbolt negotiation failure — 2026-10-13

## Observed configuration

MacBook Pro (M5 Max) → 2026 Studio Display → iMac18,3 (macOS 13.7.8).
The Studio Display upstream link reports 80 Gb/s. Its downstream link detects
the iMac domain but reports `Unknown Cross Domain Device`, sometimes at 20 Gb/s.
This is a failed state, not a usable throughput measurement.

## Failure boundary

- Both `bridge0` interfaces are inactive and have no IPv4 address.
- Sender is running with automatic retry and Thunderbolt-only selection.
- Receiver is running and listening on TCP 54321.
- iMac is awake and holds an idle-system-sleep prevention assertion.
- MacBook `IOThunderboltXDomainLink` is registered and matched.
- iMac `IOThunderboltXDomainLink` is active but not registered or matched.

These observations locate the failure before display transport. They suggest
cross-domain negotiation/driver state failure; they do not establish whether the
hub, iMac controller, cable, or an OS interoperability bug is the root cause.
`Unknown Cross Domain Device` alone is insufficient to diagnose a bad cable.

## Recovery attempts and results

1. Sent remote user-activity wake and activated the existing receiver: no link.
2. Reseated the cable: device appeared, but networking stayed inactive.
3. Disabled/re-enabled MacBook Thunderbolt Bridge with administrator authorization:
   service returned enabled; networking remained inactive.
4. Owner power-cycled Studio Display: upstream recovered; downstream first absent,
   then returned to the same unknown-device state.
5. Attempted the same network-service reset on the iMac through an administrator
   AppleScript request: macOS rejected authorization with error -60007. The reset
   did not execute.

No app build, code-signature replacement, privacy reset, kernel-driver unloading,
or OS upgrade was performed during this investigation.

## Durable resolution and acceptance gates

The previously working chain is not a demonstrated reliable configuration.
The existing high-bandwidth design requires an operational Thunderbolt IP link;
application retry cannot replace missing OS networking.

Next isolation and candidate permanent configuration: retain Studio Display on
its own MacBook port and connect the iMac directly to a separate MacBook port.
This has not been tested during the present failure and is not a guaranteed fix.
If direct connection also fails, investigate the iMac endpoint/controller state
before changing the streaming pipeline.

Accept a configuration only after repeated hot-plug and source sleep/wake tests:
both bridges active, valid IP addresses, established sender/receiver TCP session,
native 5120×2880 extended display, continuing received/presented frames, and
physical confirmation from the owner. A single successful reconnection is not
proof of a permanent repair.

Network fallback is a separate design choice. Full raw 5K streaming must not be
silently redirected over campus Wi-Fi: capacity, fidelity, peer authentication,
and recovery back to Thunderbolt need explicit validation.

## Direct-connection isolation result

The owner subsequently connected the iMac directly to MacBook receptacle 2.
Both ends immediately advertised the Internet Protocol service; the physical
link reported 40 Gb/s and both bridges obtained link-local addresses.
This isolates the earlier negotiation failure to the chained configuration
under the conditions of this test, without proving which component is at fault.

A second failure remained: TCP attempts reached ready, then received a reset
from the receiver before any profile arrived. The sender's six-attempt
pre-profile budget was exhausted repeatedly. Source inspection shows an outer
automatic-retry loop, so that log alone does not prove retries stopped forever.
Restarting the existing sender alone did not resolve the peer resets.
Gracefully restarting the installed receiver did: the new receiver logged
`session=profile-sent capture=5120x2880 dpcm=true`, accepted the physical 5K
presentation gate, and logged `session=live gpuSuccessful=1`.

The owner's required final topology remains iMac → Studio Display → MacBook.
Direct connection is diagnostic evidence, not an accepted permanent solution.
The chained topology still needs retesting after this receiver recovery, and
neither its negotiation issue nor the receiver's stale state is permanently
fixed by the successful direct session.

## Return-to-hub test

After direct streaming was confirmed and the receiver remained running, the
owner returned the cable to the Studio Display. The MacBook again reported the
iMac domain beneath the Studio Display as `Unknown Cross Domain Device`, and
both bridges became inactive with no IPv4 address. No TCP display session was
established. This reproduces the chained-path failure independently of the
previous stale receiver process. Direct-path success is not acceptance of the
required single-upstream-cable workflow.

## Kernel and change-history evidence

iMac kernel log at 14:15:23 reported `AppleThunderboltIPTransmitter::processTimeout`
with `WARNING: out of logout retries, giving up`. At 14:35:16 and 14:35:32,
power-management logs reported waiting on the Thunderbolt controller and
`IOThunderboltXDomainLink`. These are clues to teardown/wake state, not proof
of causality. The iMac had been up for 19 days. Ventura 13.7.8 was installed
August 29; MacBook macOS 27.0 was installed September 15. A known successful
chained run on September 24 postdates that upgrade, so the upgrade date alone
does not establish an OS regression.

The direct working connection used MacBook receptacle 2; the chained failures
used receptacle 1. Their host Thunderbolt domain UUIDs differ. A controlled
next test is to retain the iMac behind the Studio Display but move only the
Studio Display upstream cable to receptacle 2. This preserves the requested
topology while testing a different host controller/domain. Outcome pending.
