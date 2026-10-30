# Receiver presentation timeout — 2026-10-19

The Studio Display chain was confirmed healthy at 40 Gb/s when the owner
reported another disconnect. Both Thunderbolt Bridge interfaces were active,
with valid link-local addresses. This incident is distinct from the earlier
cross-domain negotiation failure.

At 13:32:45 Eastern, receiver PID 7745 logged:

- `session=failed reason=presentation-callback-timeout`
- `rendererFailures=1`, `presentationDrainTimedOut=true`
- 65,484 received DPCM frames, zero malformed packets and zero receive queue drops
- 61,339 presented frames and 4,144 presentation drops
- maximum presentation gap 329,151.176 ms
- reported Metal allocation 316.55 MiB

The sender repeatedly exhausted its pre-profile retry budget while the receiver
continued listening. These counters do not prove what originally prevented the
presentation callback; the gap could include lifecycle pauses. They do establish
a renderer/presentation failure followed by unsuccessful session recovery.

Graceful termination of only the installed receiver at 13:34:29 allowed its
existing LaunchAgent to restart it. At 13:34:30 the new receiver sent its 5K
profile; at 13:34:31 it logged `session=live gpuSuccessful=1 submitted=2`, and
subsequently logged active cursor ownership. The sender process did not need
restarting. macOS again reported the native 5120×2880 extended display with
2560×1440 logical scaling and a 60 Hz mode.

Restoration is verified. A permanent receiver recovery fix is not deployed.
The next code investigation should trace presentation-timeout teardown and
subsequent connection admission, including whether renderer failure state
survives between sessions. A connected TCP socket or listening port alone must
not be treated as proof of a healthy display.
