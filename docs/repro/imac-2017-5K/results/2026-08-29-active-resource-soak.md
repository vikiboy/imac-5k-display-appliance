# One-hour active 5K resource baseline — 2026-08-29

This is a baseline for the lossless whole-frame DPCM path on the exact 2017
27-inch iMac. It is intentionally recorded as a **qualified failure**, not as a
production release result: every bounded-resource gate passed except the
receiver's strict post-warm-up RSS-slope gate.

The privacy-scrubbed source samples are in
[`2026-08-29-active-resource-soak.tsv`](2026-08-29-active-resource-soak.tsv).
The collector ran for 3,600 seconds at 60-second intervals. The summary below
excludes the first 600 seconds and therefore uses 51 steady-state samples per
machine over 3,000 seconds.

| Endpoint | Mean CPU | Max CPU | First → last RSS | RSS slope | Threads | FDs |
|---|---:|---:|---:|---:|---:|---:|
| MacBook sender | 39.93% | 57.60% | 261,456 → 249,600 KiB | -22.141 MiB/hour | 11–14 | 19 |
| iMac receiver | 56.14% | 68.60% | 97,480 → 103,268 KiB | +6.251 MiB/hour | 7 | 12 |

Both processes remained alive for every sample. Application-bundle,
Application Support, and log sizes remained exactly flat; the hot path wrote
no frame files. Neither Mac reported a thermal or performance warning. The
MacBook remained on AC at 100%, so this run does not claim a battery-energy
measurement.

After the sender stopped, receiver CPU fell from roughly 52–56% to 0.0% within
the next observation. This attributes the sustained active load to continuous
whole-frame transport/presentation rather than to the resource collector or an
idle runaway loop.

## Memory investigation

At the end of the active run, `leaks` reported zero leaked allocations and zero
leaked bytes. `heap -s` showed one intentional fixed 64 MiB packet buffer and
otherwise small, stable ordinary allocations. `vmmap -summary` attributed most
resident writable memory to `IOAccelerator` (about 87.6 MiB), while three
IOSurfaces occupied 168.8 MiB of virtual address space but no resident pages in
that snapshot.

Those observations make an ordinary malloc leak unlikely, but they do not
prove that the +6.251 MiB/hour RSS trend is bounded GPU/driver residency. The
next receiver records Metal `currentAllocatedSize` at each session boundary so
the follow-up run can separate application-owned Metal growth from driver
working-set behavior.

## Qualification

- **Pass:** process liveness, FD count, thread count, storage, log growth,
  heap-leak scan, and macOS thermal/performance-warning checks.
- **Pass with expected cost:** continuous native whole-frame presentation
  consumed roughly 40% of one MacBook CPU core and 56% of one iMac CPU core.
- **Fail:** receiver RSS slope exceeded the project's ≤2 MiB/hour release gate.
- **Open:** cadence in this run used packet-completion timestamps; locked-60
  qualification requires the new hardware `MTLDrawable.presentedTime`
  telemetry under a bounded motion target.

This result motivates two separate changes: bounded two-slot receive overlap
for cadence, and deterministic changed-region transport for lower idle
bandwidth/heat. Neither is accepted merely because it is plausible; each must
pass its own A/B gate without changing the exact Retina pixels.

The first cadence A/B is now recorded in the
[2026-08-30 serial/overlap result](2026-08-30-serial-overlap-ab.md). Its
[20-minute resource follow-up](2026-08-30-overlap-resource-followup.md) stayed
within the short-run RSS gate, but neither record clears the final one-hour
gate or supersedes the corrected presentation telemetry required by version
0.5.
